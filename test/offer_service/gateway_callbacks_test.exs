defmodule OfferService.GatewayCallbacksTest do
  use OfferService.DataCase, async: false
  use Oban.Testing, repo: OfferService.Repo

  import Ecto.Query

  alias Ecto.Multi
  alias OfferService.Auction.{Acceptance, Edit, Expire, OfferEvent, Reject, Submit, Withdraw}
  alias OfferService.GatewayCallbacks
  alias OfferService.Repo
  alias OfferService.Workers.GatewayCallbackWorker

  @worker_name Oban.Worker.to_string(GatewayCallbackWorker)
  @callback_config [
    enabled: true,
    base_url: "https://gateway.example.test",
    path: "/svc-callbacks/notify",
    timeout_ms: 1_500,
    attempts: 7,
    locale: "en",
    request_options: [plug: {Req.Test, GatewayCallbackWorker}]
  ]

  setup do
    previous = Application.get_env(:offer_service, :gateway_callbacks)
    Application.put_env(:offer_service, :gateway_callbacks, @callback_config)

    on_exit(fn ->
      if previous do
        Application.put_env(:offer_service, :gateway_callbacks, previous)
      else
        Application.delete_env(:offer_service, :gateway_callbacks)
      end
    end)

    :ok
  end

  test "every lifecycle audit event enqueues the correct durable callback" do
    submit_request = insert_request!(%{client_id: "client-submit"})

    assert {:ok, submitted} =
             Submit.run("actor-submit", submit_request.id, %{
               fee_cents: 1_200,
               eta_minutes: 15
             })

    edit_request = insert_request!(%{client_id: "client-edit"})
    editable = insert_submitted_offer!(edit_request, %{actor_id: "actor-edit"})

    assert {:ok, edited} =
             Edit.run("actor-edit", edit_request.id, editable.id, %{fee_cents: 1_300})

    withdraw_request = insert_request!(%{client_id: "client-withdraw"})
    withdrawable = insert_submitted_offer!(withdraw_request, %{actor_id: "actor-withdraw"})

    assert {:ok, withdrawn} =
             Withdraw.run("actor-withdraw", withdraw_request.id, withdrawable.id)

    reject_request = insert_request!(%{client_id: "client-reject"})
    rejectable = insert_submitted_offer!(reject_request, %{actor_id: "actor-rejected"})
    assert {:ok, rejected} = Reject.run("client-reject", rejectable.id)

    expire_request = insert_request!(%{client_id: "client-expire"})
    expirable = insert_submitted_offer!(expire_request, %{actor_id: "actor-expired"})
    assert {:ok, expired} = Expire.run("system", expirable.id)

    accept_request = insert_request!(%{client_id: "client-accept"})
    winner = insert_submitted_offer!(accept_request, %{actor_id: "actor-winner"})
    sibling = insert_submitted_offer!(accept_request, %{actor_id: "actor-sibling"})

    assert {:ok, %{accepted_offer: accepted, rejected_offer_ids: [sibling_id]}} =
             Acceptance.run("client-accept", accept_request.id, winner.id)

    assert sibling_id == sibling.id

    jobs = callback_jobs()
    assert length(jobs) == 7
    assert Enum.all?(jobs, &(&1.max_attempts == 7))

    expected = %{
      {submitted.id, "submit"} => {"client-submit", "jeeb.offer_received"},
      {edited.id, "edit"} => {"client-edit", "jeeb.offer_updated"},
      {withdrawn.id, "withdraw"} => {"client-withdraw", "jeeb.offer_updated"},
      {rejected.id, "reject"} => {"actor-rejected", "jeeb.offer_updated"},
      {expired.id, "expire"} => {"actor-expired", "jeeb.offer_updated"},
      {accepted.id, "accept"} => {"actor-winner", "jeeb.offer_accepted"},
      {sibling.id, "reject"} => {"actor-sibling", "jeeb.offer_updated"}
    }

    actual =
      Map.new(jobs, fn job ->
        payload = job.args["payload"]
        data = payload["data"]

        {{data["offerId"], data["action"]},
         {payload["recipientUserId"], payload["notificationType"]}}
      end)

    assert actual == expected

    assert Repo.get_by!(OfferEvent, offer_id: sibling.id, action: "reject").payload == %{
             "sibling_of" => winner.id
           }
  end

  test "audit row and Oban job roll back with the surrounding transaction" do
    request = insert_request!(%{client_id: "client-rollback"})
    offer = insert_submitted_offer!(request, %{actor_id: "actor-rollback"})

    changeset =
      OfferEvent.new_changeset(%{
        offer_id: offer.id,
        request_id: request.id,
        actor_id: offer.actor_id,
        action: "edit",
        from_state: "submitted",
        to_state: "edited",
        payload: %{},
        inserted_at: DateTime.utc_now()
      })

    result =
      Multi.new()
      |> Multi.insert(:audit, changeset)
      |> GatewayCallbacks.multi_enqueue(:gateway_callback, :audit, fn _ -> request.client_id end)
      |> Multi.run(:force_rollback, fn _repo, _changes -> {:error, :forced} end)
      |> Repo.transaction()

    assert {:error, :force_rollback, :forced, _changes} = result
    refute Repo.get_by(OfferEvent, offer_id: offer.id, action: "edit")
    assert callback_jobs() == []
  end

  test "job payload is exact and a 2xx response completes delivery" do
    request = insert_request!(%{client_id: "client-payload"})

    assert {:ok, offer} =
             Submit.run("actor-payload", request.id, %{fee_cents: 1_250, eta_minutes: 20})

    [job] = callback_jobs()
    event = Repo.get_by!(OfferEvent, offer_id: offer.id, action: "submit")

    expected_payload = %{
      "notificationType" => "jeeb.offer_received",
      "recipientUserId" => request.client_id,
      "locale" => "en",
      "silent" => false,
      "idempotencyKey" => "offer-event:#{event.id}:recipient:#{request.client_id}",
      "data" => %{
        "entityId" => offer.id,
        "offerId" => offer.id,
        "requestId" => request.id,
        "action" => "submit",
        "fromStatus" => "",
        "toStatus" => "submitted",
        "actorId" => "actor-payload",
        "occurredAt" => DateTime.to_iso8601(event.inserted_at)
      }
    }

    assert job.args == %{
             "event_id" => event.id,
             "recipient_user_id" => request.client_id,
             "payload" => expected_payload
           }

    Req.Test.expect(GatewayCallbackWorker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.method == "POST"
      assert conn.request_path == "/svc-callbacks/notify"
      assert Jason.decode!(body) == expected_payload

      conn
      |> Plug.Conn.put_status(202)
      |> Req.Test.json(%{"status" => "Queued"})
    end)

    assert :ok = perform_job(GatewayCallbackWorker, job.args)
    Req.Test.verify!(GatewayCallbackWorker)
  end

  test "non-2xx and transport failures are returned to Oban for retry" do
    args = %{
      "event_id" => Ecto.UUID.generate(),
      "recipient_user_id" => "recipient-retry",
      "payload" => %{"notificationType" => "jeeb.offer_updated"}
    }

    Req.Test.expect(GatewayCallbackWorker, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "temporary"})
    end)

    assert {:error, "gateway callback returned HTTP 503"} =
             perform_job(GatewayCallbackWorker, args)

    Req.Test.expect(GatewayCallbackWorker, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             perform_job(GatewayCallbackWorker, args)

    Req.Test.verify!(GatewayCallbackWorker)
  end

  defp callback_jobs do
    Repo.all(from job in Oban.Job, where: job.worker == ^@worker_name, order_by: job.inserted_at)
  end
end
