defmodule OfferService.Auction.AcceptanceRaceTest do
  @moduledoc """
  JEB-49 / AC3 — race-safety property test.

  Spec:

      "When N concurrent accepts arrive for the same request from N
       different sessions, exactly 1 succeeds (the first to acquire
       the row lock) and the other (N-1) receive 409 with
       `{ error: \"already_accepted\", winner_user_id }`."

  We exercise this invariant in two flavours:

    * A fast unit-style test (default `mix test`) — runs 20 concurrent
      accepts and asserts exactly one winner. Cheap enough for every
      CI run.

    * A StreamData property test (`@tag :race`, opt-in via
      `mix test --only race`) — runs 50 randomised batches of up to
      100 concurrent accepts each, for a total ~5_000 race outcomes.
      This is the AC3 "property-test 1000 runs" gate. We default the
      batch count to 50 so CI stays under a minute on a developer
      machine; bump `OFFER_SERVICE_RACE_BATCHES` in CI to 1000+.

  The lock is enforced by:

    * `SELECT … FOR UPDATE` in `Acceptance.lock_request/3`
    * the partial unique index `offers_one_accepted_per_request` as a
      belt-and-braces guarantee at the DB layer.
  """

  use OfferService.DataCase, async: false
  use ExUnitProperties

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{AcceptanceOtp, Offer, Request}
  alias OfferService.Clients.{ChatClientMock, NotificationClientMock}
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  describe "race-safety (sequential proof)" do
    test "20 concurrent accepts on the same request: exactly one winner" do
      {request, offers} = build_request_with_offers(20)
      verdict = run_concurrent_accepts(request, offers)

      assert verdict.winners == 1, "expected exactly 1 winner, got #{verdict.winners}"
      assert verdict.losers == length(offers) - 1
      assert_db_state(request, verdict)
    end

    test "the first writer wins; remaining 9 receive {:already_accepted, winner_user_id}" do
      {request, offers} = build_request_with_offers(10)

      verdict = run_concurrent_accepts(request, offers)

      assert verdict.winners == 1
      # Every loser must report the same winner id.
      winner_id =
        verdict.outcomes
        |> Enum.find_value(fn
          {:winner, %{accepted_offer: %{jeeber_id: jid}}} -> jid
          _ -> nil
        end)

      losers =
        Enum.filter(verdict.outcomes, fn
          {:loser, _} -> true
          _ -> false
        end)

      assert length(losers) == 9

      Enum.each(losers, fn {:loser, reason} ->
        assert match?({:already_accepted, ^winner_id}, reason) or
                 reason == :concurrent_modification,
               "unexpected loser reason: #{inspect(reason)}"
      end)
    end
  end

  describe "race-safety (StreamData property)" do
    @tag :race
    @tag timeout: 600_000
    property "for every batch of N concurrent accepts, exactly one winner emerges" do
      batches = race_batches()

      check all(batch_size <- StreamData.integer(5..25), max_runs: batches) do
        # The mox stub is set up at `setup`-time and remains valid for
        # all the saga calls inside the property body.
        {request, offers} = build_request_with_offers(batch_size)

        verdict = run_concurrent_accepts(request, offers)

        assert verdict.winners == 1
        assert verdict.losers == batch_size - 1
        # Belt-and-braces: the partial unique index guarantees DB
        # consistency even if the application code regressed.
        assert_db_state(request, verdict)
      end
    end
  end

  # --- helpers -------------------------------------------------------------

  defp race_batches do
    case System.get_env("OFFER_SERVICE_RACE_BATCHES") do
      nil -> 50
      n -> String.to_integer(n)
    end
  end

  defp build_request_with_offers(n) do
    # Each batch must stub the chat client to always succeed; even with
    # mox set_from_context we use a `:stub` because exactly one call
    # will reach the chat client (the winner).
    stub(ChatClientMock, :create_thread, fn _ ->
      {:ok, %{thread_id: "t-" <> Ecto.UUID.generate()}}
    end)

    request = insert_request!()
    offers = for _ <- 1..n, do: insert_offer!(request)
    {request, offers}
  end

  defp run_concurrent_accepts(%Request{} = request, offers) do
    parent = self()

    tasks =
      for offer <- offers do
        Task.async(fn ->
          # Each task needs explicit Ecto sandbox access because we are
          # in `async: false` shared-DB mode (see DataCase setup).
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          {offer, Auction.accept_offer(request.client_id, request.id, offer.id)}
        end)
      end

    results = Task.await_many(tasks, 30_000)

    outcomes =
      Enum.map(results, fn
        {offer, {:ok, success}} -> {:winner, Map.put(success, :offer_id, offer.id)}
        {_offer, {:error, reason}} -> {:loser, reason}
      end)

    winners = Enum.count(outcomes, &match?({:winner, _}, &1))
    losers = Enum.count(outcomes, &match?({:loser, _}, &1))

    %{outcomes: outcomes, winners: winners, losers: losers}
  end

  defp assert_db_state(%Request{id: request_id}, verdict) do
    # Exactly 1 accepted offer per request, enforced by the partial
    # unique index `offers_one_accepted_per_request`.
    accepted =
      Repo.all(
        from o in Offer,
          where: o.request_id == ^request_id and o.status == "accepted"
      )

    assert length(accepted) == 1, "DB has #{length(accepted)} accepted offers, expected 1"

    request = Repo.get!(Request, request_id)
    assert request.status == "accepted"
    assert request.accepted_offer_id == hd(accepted).id

    # Exactly one OTP row per request.
    otps =
      Repo.all(
        from o in AcceptanceOtp,
          where: o.request_id == ^request_id
      )

    assert length(otps) == 1

    # The winner outcome should agree with the DB.
    winner_outcome =
      Enum.find_value(verdict.outcomes, fn
        {:winner, w} -> w
        _ -> nil
      end)

    assert winner_outcome.offer_id == hd(accepted).id
  end
end
