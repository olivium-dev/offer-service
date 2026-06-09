defmodule OfferService.Auction.Acceptance do
  @moduledoc """
  Implements the auction-close flow for `POST /requests/:id/offers/:id/accept`.

  The flow runs in a single Postgres transaction so that the state changes
  — accept-target / reject-siblings / persist-OTP — either all commit or all
  roll back. Concurrent acceptance attempts are blocked at two levels:

    1. The request row is locked with `SELECT ... FOR UPDATE`.
    2. The `Request` row carries a `lock_version` integer; the changeset uses
       `Ecto.Changeset.optimistic_lock/2`, so a stale read raises
       `Ecto.StaleEntryError` and the whole transaction is rolled back.

  Side-effects that must NOT participate in the database transaction (push
  notifications) are dispatched after a successful commit via
  `Task.Supervisor.start_child/2`, so a slow downstream cannot stall the API
  response or hold a connection in the pool.

  Returned value on success: `{:ok, %{otp_code: ..., thread_id: nil, ...}}`.
  The OTP plaintext is returned exactly once to the Client; only a SHA-256
  hash is persisted.

  ## Chat provisioning (fix C — no-coupling LAW)

  offer-service holds NO chat client. Conversation provisioning for an accepted
  offer is owned exclusively by the gateway BFF
  (`ChatServiceConversationProvisioner`), which orchestrates request-sync,
  delivery-create, and chat-advance after a successful accept. The
  `chat_thread_id` column and the `thread_id` response key are retained for
  backward-compatibility but are always `nil` here — they are never written by
  this service. Microservices never call each other; all cross-service
  composition lives in the gateway.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias OfferService.Auction.{AcceptanceOtp, AuditLog, Offer, OfferEvent, OTP, Request}
  alias OfferService.Clients.NotificationClient
  alias OfferService.Repo

  # Opaque external identity (gateway JWT `sub`), not necessarily a uuid.
  @type acceptor_id :: binary()
  @type request_id :: Ecto.UUID.t()
  @type offer_id :: Ecto.UUID.t()
  @type opts :: [confirm_high_fee: boolean(), authorize: boolean()]

  @type success :: %{
          request: Request.t(),
          accepted_offer: Offer.t(),
          rejected_offer_ids: [Ecto.UUID.t()],
          otp_code: binary(),
          thread_id: Ecto.UUID.t() | nil
        }

  @type error_reason ::
          :not_found
          | :forbidden
          | :request_not_open
          | :request_expired
          | :request_cancelled
          | :offer_not_pending
          | :offer_withdrawn
          | :offer_expired
          | {:already_accepted, Ecto.UUID.t() | nil}
          | :already_accepted
          | :concurrent_modification
          | :high_fee_confirmation_required

  @spec run(acceptor_id(), request_id(), offer_id(), opts()) ::
          {:ok, success()} | {:error, error_reason()}
  def run(actor_id, request_id, offer_id, opts \\ []) do
    confirm_high_fee? = Keyword.get(opts, :confirm_high_fee, false)
    # `authorize: false` bypasses the request-CLIENT ownership guard below. It
    # is reserved for internal/trusted callers that have ALREADY authorized the
    # actor out-of-band; no HTTP route currently sets it. Both public accept
    # routes — request-scoped (`POST /requests/:id/offers/:id/accept`) and
    # offer-scoped (`POST /offers/:offer_id/accept`) — keep the default `true`,
    # so the client-ownership guard (`request.client_id == actor_id` => 403) is
    # the single source of truth. Lifecycle/race/410/409 logic below is
    # identical regardless of the `authorize?` value.
    authorize? = Keyword.get(opts, :authorize, true)
    threshold = Application.get_env(:offer_service, :high_fee_threshold_cents, 5_000)
    started_at = System.monotonic_time()

    result =
      Multi.new()
      |> Multi.run(:request, fn repo, _ -> lock_request(repo, request_id, actor_id, authorize?) end)
      |> Multi.run(:offer, fn repo, %{request: r} -> load_target_offer(repo, r.id, offer_id) end)
      |> Multi.run(:high_fee_guard, fn _repo, %{offer: o} ->
        check_high_fee(o, confirm_high_fee?, threshold)
      end)
      |> Multi.update(:accepted_offer, fn %{offer: o} -> Offer.accept_changeset(o, now()) end)
      |> Multi.run(:rejected_offer_ids, fn repo, %{request: r, offer: o} ->
        reject_siblings(repo, r.id, o.id)
      end)
      |> Multi.run(:otp, fn repo, %{request: r, accepted_offer: o} ->
        insert_otp(repo, r.id, o.id)
      end)
      # offer-service never provisions chat (fix C / no-coupling LAW). The
      # request commits with `chat_thread_id: nil`; the gateway BFF owns chat
      # provisioning after a successful accept.
      |> Multi.update(:final_request, fn %{request: r, accepted_offer: o} ->
        Request.accept_changeset(r, %{
          accepted_offer_id: o.id,
          chat_thread_id: nil
        })
      end)
      |> Multi.insert(:audit_accept, fn %{offer: prev, accepted_offer: next} ->
        OfferEvent.new_changeset(%{
          offer_id: next.id,
          request_id: next.request_id,
          actor_id: actor_id,
          action: "accept",
          from_state: prev.status,
          to_state: next.status,
          payload: %{"fee_cents" => next.fee_cents},
          inserted_at: DateTime.utc_now()
        })
      end)
      |> Repo.transaction()
      |> handle_result(actor_id)

    emit_accept_outcome(result, request_id, started_at)
    result
  rescue
    Ecto.StaleEntryError ->
      :telemetry.execute(
        [:offer, :accept, :outcome],
        %{count: 1, duration: 0},
        %{outcome: :concurrent_modification}
      )

      {:error, :concurrent_modification}
  end

  # AC7 — emit `offer_accept_total{outcome}` and a structured log.
  defp emit_accept_outcome(result, request_id, started_at) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    {outcome, extra} =
      case result do
        {:ok, %{accepted_offer: accepted}} ->
          {:ok, %{winner_user_id: accepted.jeeber_id}}

        {:error, {:already_accepted, winner}} ->
          {:already_accepted, %{winner_user_id: winner}}

        {:error, reason} when is_atom(reason) ->
          {reason, %{}}

        _ ->
          {:error, %{}}
      end

    :telemetry.execute(
      [:offer, :accept, :outcome],
      %{count: 1, duration: duration_ms},
      Map.merge(%{outcome: outcome, request_id: request_id}, extra)
    )

    Logger.info("offer.accepted",
      request_id: request_id,
      outcome: outcome,
      latency_ms: duration_ms,
      winner_user_id: extra[:winner_user_id]
    )
  end

  # --- Multi steps ---------------------------------------------------------

  defp lock_request(repo, request_id, actor_id, authorize?) do
    query =
      from r in Request,
        where: r.id == ^request_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      # Client-ownership guard — the authorized acceptor is the CLIENT who owns
      # the parent request (`request.client_id == actor_id`). A Jeeber, or any
      # other actor, is rejected with 403. Both public accept routes
      # (request-scoped and offer-scoped) reach this clause; only trusted
      # internal callers opt out via `authorize: false`.
      %Request{client_id: client_id} when authorize? and client_id != actor_id ->
        {:error, :forbidden}

      %Request{status: "open"} = request ->
        {:ok, request}

      # JEB-49 / AC3 — race-loss path. The second of two simultaneous
      # `Accept` calls blocks on the row-lock above; once the first
      # commits, this transaction sees the request already accepted
      # and returns the winning Jeeber's user id so the API caller can
      # render `{ error: "already_accepted", winner_user_id }`.
      %Request{status: "accepted"} = request ->
        {:error, {:already_accepted, winner_user_id(repo, request)}}

      # JEB-49 / AC4 — terminal lifecycle states map to HTTP 410.
      %Request{status: "expired"} ->
        {:error, :request_expired}

      %Request{status: "cancelled"} ->
        {:error, :request_cancelled}

      %Request{} ->
        {:error, :request_not_open}
    end
  end

  defp winner_user_id(_repo, %Request{accepted_offer_id: nil}), do: nil

  defp winner_user_id(repo, %Request{accepted_offer_id: accepted_offer_id}) do
    case repo.get(Offer, accepted_offer_id) do
      %Offer{jeeber_id: jid} -> jid
      _ -> nil
    end
  end

  defp load_target_offer(repo, request_id, offer_id) do
    case repo.get_by(Offer, id: offer_id, request_id: request_id) do
      nil ->
        {:error, :not_found}

      %Offer{status: s} = offer when s in ["pending", "submitted", "edited"] ->
        {:ok, offer}

      %Offer{status: "withdrawn"} ->
        {:error, :offer_withdrawn}

      # Terminal lifecycle state — accepting an expired offer maps to HTTP 410
      # (BR-OFR-8), distinct from the 409 catch-all below. The `:offer_expired`
      # tag is already mapped to 410 in `OfferServiceWeb.FallbackController`.
      %Offer{status: "expired"} ->
        {:error, :offer_expired}

      %Offer{status: "accepted"} ->
        {:error, :already_accepted}

      _ ->
        {:error, :offer_not_pending}
    end
  end

  defp check_high_fee(%Offer{fee_cents: fee}, _confirmed?, threshold) when fee <= threshold,
    do: {:ok, :under_threshold}

  defp check_high_fee(%Offer{}, true, _threshold), do: {:ok, :confirmed}

  defp check_high_fee(%Offer{}, _confirmed?, _threshold),
    do: {:error, :high_fee_confirmation_required}

  defp reject_siblings(repo, request_id, accepted_offer_id) do
    now = now()

    {count, rejected} =
      repo.update_all(
        from(o in Offer,
          where:
            o.request_id == ^request_id and
              o.id != ^accepted_offer_id and
              o.status in ["pending", "submitted", "edited"],
          select: %{id: o.id, jeeber_id: o.jeeber_id, status: o.status}
        ),
        set: [status: "rejected", rejected_at: now, updated_at: now],
        inc: [lock_version: 1]
      )

    Logger.info("offer_acceptance.rejected_siblings",
      request_id: request_id,
      accepted_offer_id: accepted_offer_id,
      rejected_count: count
    )

    {:ok, rejected}
  end

  defp insert_otp(repo, request_id, offer_id) do
    %{code: code, code_hash: hash, code_last2: last2, expires_at: expires_at} = OTP.generate()

    attrs = %{
      request_id: request_id,
      offer_id: offer_id,
      code_hash: hash,
      code_last2: last2,
      expires_at: expires_at
    }

    case repo.insert(AcceptanceOtp.new_changeset(attrs)) do
      {:ok, otp} -> {:ok, %{record: otp, plaintext: code}}
      {:error, _} = err -> err
    end
  end

  # --- Post-commit ---------------------------------------------------------

  defp handle_result({:ok, ctx}, actor_id) do
    %{
      offer: prev,
      accepted_offer: accepted,
      rejected_offer_ids: rejected,
      otp: %{plaintext: otp_code},
      final_request: final_request
    } = ctx

    rejected_ids = Enum.map(rejected, & &1.id)

    fan_out_notifications(final_request, accepted, rejected)

    AuditLog.emit_telemetry(%{
      offer_id: accepted.id,
      request_id: final_request.id,
      actor_id: actor_id,
      action: :accept,
      from_state: prev.status,
      to_state: "accepted"
    })

    Enum.each(rejected, fn %{id: id, jeeber_id: jid, status: from} ->
      AuditLog.log!(%{
        offer_id: id,
        request_id: final_request.id,
        actor_id: actor_id,
        action: :reject,
        from_state: from,
        to_state: "rejected",
        payload: %{"sibling_of" => accepted.id}
      })

      AuditLog.emit_telemetry(%{
        offer_id: id,
        request_id: final_request.id,
        actor_id: jid,
        action: :reject,
        from_state: from,
        to_state: "rejected"
      })
    end)

    {:ok,
     %{
       # chat_thread_id / thread_id are always nil here — the gateway BFF owns
       # chat provisioning (fix C / no-coupling LAW). Keys retained for
       # backward-compatible response shape.
       request: %{final_request | chat_thread_id: nil},
       accepted_offer: %{accepted | status: "accepted"},
       rejected_offer_ids: rejected_ids,
       otp_code: otp_code,
       thread_id: nil
     }}
  end

  defp handle_result({:error, _step, reason, _changes}, _actor_id) when is_atom(reason),
    do: {:error, reason}

  defp handle_result({:error, _step, {:already_accepted, winner}, _changes}, _actor_id),
    do: {:error, {:already_accepted, winner}}

  defp handle_result({:error, _step, %Ecto.Changeset{}, _changes}, _actor_id),
    do: {:error, :concurrent_modification}

  defp handle_result({:error, _step, _other, _changes}, _actor_id),
    do: {:error, :concurrent_modification}

  defp fan_out_notifications(request, accepted, rejected) do
    run = fn -> do_fan_out(request, accepted, rejected) end

    case Application.get_env(:offer_service, :fanout_strategy, :async) do
      :sync -> run.()
      :async -> Task.Supervisor.start_child(OfferService.TaskSupervisor, run)
    end
  end

  defp do_fan_out(request, accepted, rejected) do
    NotificationClient.notify(%{
      user_id: accepted.jeeber_id,
      event: :offer_accepted,
      payload: %{request_id: request.id, offer_id: accepted.id}
    })

    Enum.each(rejected, fn %{id: offer_id, jeeber_id: jeeber_id} ->
      NotificationClient.notify(%{
        user_id: jeeber_id,
        event: :offer_rejected,
        payload: %{request_id: request.id, rejected_offer_id: offer_id}
      })
    end)

    NotificationClient.notify(%{
      user_id: request.client_id,
      event: :auction_closed,
      payload: %{
        request_id: request.id,
        accepted_offer_id: accepted.id,
        rejected_count: length(rejected)
      }
    })
  end

  defp now, do: DateTime.utc_now()
end
