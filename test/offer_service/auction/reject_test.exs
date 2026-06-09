defmodule OfferService.Auction.RejectTest do
  @moduledoc """
  Domain tests for `OfferService.Auction.reject_offer/2` (S08 / A5).

  Reject is the CLIENT declining one Jeeber bid (offer-scoped, resolves the
  request from the offer, authorized by `request.client_id`). It is the mirror
  image of Withdraw (the Jeeber retracting its own bid) and, unlike Acceptance,
  it does NOT close the auction — the request stays `open`.
  """
  use OfferService.DataCase, async: false

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, OfferEvent, Request}
  alias OfferService.Clients.NotificationClientMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Reject fans the :offer_rejected push synchronously in tests; stub it.
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  describe "reject_offer/2 — happy path" do
    test "the request CLIENT rejects a submitted offer -> rejected + rejected_at" do
      client = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:ok, %Offer{} = rejected} = Auction.reject_offer(client, offer.id)

      assert rejected.status == "rejected"
      refute is_nil(rejected.rejected_at)
      assert Repo.get!(Offer, offer.id).status == "rejected"
    end

    test "an edited offer can be rejected and preserves edits_count" do
      client = uuid()
      jeeber = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})
      {:ok, edited} = Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_200})

      assert {:ok, %{status: "rejected", edits_count: 1}} = Auction.reject_offer(client, edited.id)
    end

    test "rejecting one bid leaves the request OPEN (auction not closed)" do
      client = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} = Auction.reject_offer(client, offer.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "open"
      assert is_nil(reloaded.accepted_offer_id)
    end

    test "the Client can still accept a DIFFERENT offer after rejecting one" do
      client = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, loser} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 15})
      {:ok, winner} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 900, eta_minutes: 20})

      {:ok, _} = Auction.reject_offer(client, loser.id)

      assert {:ok, %{accepted_offer: %{id: id, status: "accepted"}}} =
               Auction.accept_offer(client, request.id, winner.id)

      assert id == winner.id
    end

    test "audit log records the reject action with the Client as actor" do
      client = uuid()
      jeeber = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} = Auction.reject_offer(client, offer.id)

      event =
        OfferEvent
        |> Repo.all()
        |> Enum.find(&(&1.action == "reject"))

      assert event
      assert event.from_state == "submitted"
      assert event.to_state == "rejected"
      # Reject records the CLIENT (Withdraw records the Jeeber).
      assert event.actor_id == client
      assert event.payload["jeeber_id"] == jeeber
    end

    test "fans an :offer_rejected push to the losing Jeeber" do
      client = uuid()
      jeeber = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      test_pid = self()

      expect(NotificationClientMock, :notify, fn params ->
        send(test_pid, {:notified, params})
        :ok
      end)

      {:ok, _} = Auction.reject_offer(client, offer.id)

      assert_receive {:notified, %{event: :offer_rejected, user_id: ^jeeber}}
    end
  end

  describe "reject_offer/2 — authorization & negatives" do
    test "the offer's OWN Jeeber cannot reject its bid (:forbidden)" do
      request = insert_request!(%{client_id: uuid()})
      jeeber = uuid()
      {:ok, offer} = Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:error, :forbidden} = Auction.reject_offer(jeeber, offer.id)
      # The offer is untouched.
      assert Repo.get!(Offer, offer.id).status == "submitted"
    end

    test "a stranger (neither client nor jeeber) cannot reject (:forbidden)" do
      request = insert_request!(%{client_id: uuid()})
      {:ok, offer} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:error, :forbidden} = Auction.reject_offer(uuid(), offer.id)
    end

    test "a phantom offer id returns :not_found" do
      assert {:error, :not_found} = Auction.reject_offer(uuid(), uuid())
    end

    test "re-rejecting an already-rejected offer is idempotent-error (:already_rejected)" do
      client = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 15})
      {:ok, _} = Auction.reject_offer(client, offer.id)

      assert {:error, :already_rejected} = Auction.reject_offer(client, offer.id)
    end

    test "rejecting a withdrawn offer returns :offer_withdrawn" do
      client = uuid()
      jeeber = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})
      {:ok, _} = Auction.withdraw_offer(jeeber, request.id, offer.id)

      assert {:error, :offer_withdrawn} = Auction.reject_offer(client, offer.id)
    end

    test "rejecting an accepted offer returns :already_accepted" do
      client = uuid()
      request = insert_request!(%{client_id: client})
      {:ok, offer} = Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 15})
      {:ok, _} = Auction.accept_offer(client, request.id, offer.id)

      assert {:error, :already_accepted} = Auction.reject_offer(client, offer.id)
    end
  end
end
