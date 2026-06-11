defmodule OfferService.Auction.WithdrawTest do
  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, OfferEvent}

  describe "withdraw_offer/3" do
    test "submitted → withdrawn writes withdrawn_at" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:ok, %Offer{} = withdrawn} =
               Auction.withdraw_offer(jeeber, request.id, offer.id)

      assert withdrawn.status == "withdrawn"
      refute is_nil(withdrawn.withdrawn_at)
      assert Repo.get!(Offer, offer.id).status == "withdrawn"
    end

    test "edited → withdrawn preserves edits_count" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, edited} = Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_200})

      assert {:ok, %{status: "withdrawn", edits_count: 1}} =
               Auction.withdraw_offer(jeeber, request.id, edited.id)
    end

    test "AC4: withdrawn offer cannot be re-withdrawn (:offer_withdrawn)" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} = Auction.withdraw_offer(jeeber, request.id, offer.id)

      assert {:error, :offer_withdrawn} =
               Auction.withdraw_offer(jeeber, request.id, offer.id)
    end

    test "AC4: accept on a withdrawn offer returns :offer_withdrawn" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} = Auction.withdraw_offer(jeeber, request.id, offer.id)

      assert {:error, :offer_withdrawn} =
               Auction.accept_offer(request.client_id, request.id, offer.id)
    end

    test "rejects withdraw by another jeeber (:forbidden)" do
      request = insert_request!()
      owner = uuid()
      attacker = uuid()
      {:ok, offer} = Auction.submit_offer(owner, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:error, :forbidden} =
               Auction.withdraw_offer(attacker, request.id, offer.id)
    end

    test "audit log records the withdraw action" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} = Auction.withdraw_offer(jeeber, request.id, offer.id)

      events = OfferEvent |> Repo.all() |> Enum.sort_by(& &1.inserted_at)

      assert Enum.any?(events, &(&1.action == "withdraw"))
      withdraw_event = Enum.find(events, &(&1.action == "withdraw"))
      assert withdraw_event.from_state == "submitted"
      assert withdraw_event.to_state == "withdrawn"
      assert withdraw_event.actor_id == jeeber
    end

    test "AC3 integration: submitted offer can still be accepted normally" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:ok, %{accepted_offer: %{id: id, status: "accepted"}}} =
               Auction.accept_offer(request.client_id, request.id, offer.id)

      assert id == offer.id
    end
  end
end
