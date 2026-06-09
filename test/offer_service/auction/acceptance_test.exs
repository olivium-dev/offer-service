defmodule OfferService.Auction.AcceptanceTest do
  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, Request}
  alias OfferService.Repo

  describe "accept_offer/4 — happy path" do
    test "accepts exactly one offer per request and auto-rejects all others" do
      request = insert_request!()
      target = insert_offer!(request, %{fee_cents: 2_000})
      sibling_a = insert_offer!(request, %{fee_cents: 1_800})
      sibling_b = insert_offer!(request, %{fee_cents: 1_900})

      assert {:ok, result} =
               Auction.accept_offer(request.client_id, request.id, target.id)

      assert result.accepted_offer.id == target.id
      assert MapSet.new(result.rejected_offer_ids) == MapSet.new([sibling_a.id, sibling_b.id])

      # DB state: exactly one accepted
      offers = Repo.all(Offer)
      accepted = Enum.filter(offers, &(&1.status == "accepted"))
      rejected = Enum.filter(offers, &(&1.status == "rejected"))

      assert length(accepted) == 1
      assert hd(accepted).id == target.id
      assert length(rejected) == 2
    end

    test "transitions the request to accepted with accepted_offer_id set" do
      request = insert_request!()
      offer = insert_offer!(request)

      assert {:ok, _result} =
               Auction.accept_offer(request.client_id, request.id, offer.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "accepted"
      assert reloaded.accepted_offer_id == offer.id
    end

    test "returns ONLY the generic transition outcome — no OTP / chat-thread / notification side effects (JEB-1474)" do
      # Boundary regression guard: the shared accept endpoint returns the
      # accepted offer id + rejected sibling ids and nothing product-specific.
      # OTP minting, chat-thread linkage and notification fan-out are owned by
      # the consuming gateway, NOT this service.
      request = insert_request!()
      target = insert_offer!(request, %{fee_cents: 2_000})
      sibling = insert_offer!(request, %{fee_cents: 1_800})

      assert {:ok, result} =
               Auction.accept_offer(request.client_id, request.id, target.id)

      assert Map.keys(result) |> Enum.sort() ==
               [:accepted_offer, :rejected_offer_ids, :request]

      refute Map.has_key?(result, :otp_code)
      refute Map.has_key?(result, :thread_id)
      refute Map.has_key?(result, :chat_thread_id)

      assert result.accepted_offer.id == target.id
      assert MapSet.new(result.rejected_offer_ids) == MapSet.new([sibling.id])
    end
  end

  describe "accept_offer/4 — guards" do
    test "rejects offers > high-fee threshold without confirmation" do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 7_500})

      assert {:error, :high_fee_confirmation_required} =
               Auction.accept_offer(request.client_id, request.id, offer.id)

      # No mutations
      assert Repo.get!(Offer, offer.id).status == "pending"
      assert Repo.get!(Request, request.id).status == "open"
    end

    test "accepts a high-fee offer when confirm_high_fee is true" do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 7_500})

      assert {:ok, _} =
               Auction.accept_offer(request.client_id, request.id, offer.id,
                 confirm_high_fee: true
               )
    end

    test "returns :forbidden when actor is not the request owner" do
      request = insert_request!()
      offer = insert_offer!(request)

      assert {:error, :forbidden} =
               Auction.accept_offer(uuid(), request.id, offer.id)
    end

    test "returns :not_found when request does not exist" do
      assert {:error, :not_found} = Auction.accept_offer(uuid(), uuid(), uuid())
    end

    test "returns :not_found when offer does not belong to the request" do
      request_a = insert_request!()
      request_b = insert_request!()
      offer_on_b = insert_offer!(request_b)

      assert {:error, :not_found} =
               Auction.accept_offer(request_a.client_id, request_a.id, offer_on_b.id)
    end

    test "returns {:already_accepted, winner_user_id} when request is already accepted (JEB-49 / AC3)" do
      request = insert_request!()
      offer = insert_offer!(request)

      {:ok, _} = Auction.accept_offer(request.client_id, request.id, offer.id)

      second_offer = insert_offer!(request)

      assert {:error, {:already_accepted, winner_user_id}} =
               Auction.accept_offer(request.client_id, request.id, second_offer.id)

      assert winner_user_id == offer.actor_id
    end

    test "returns :request_expired (410) when request lifecycle terminal — expired (JEB-49 / AC4)" do
      request = insert_request!(%{status: "expired"})
      offer = insert_offer!(request)

      assert {:error, :request_expired} =
               Auction.accept_offer(request.client_id, request.id, offer.id)
    end

    test "returns :request_cancelled (410) when request lifecycle terminal — cancelled (JEB-49 / AC4)" do
      request = insert_request!(%{status: "cancelled"})
      offer = insert_offer!(request)

      assert {:error, :request_cancelled} =
               Auction.accept_offer(request.client_id, request.id, offer.id)
    end

    test "returns :offer_withdrawn (AC4) when target offer was already withdrawn" do
      request = insert_request!()
      offer = insert_offer!(request, %{status: "withdrawn"})

      assert {:error, :offer_withdrawn} =
               Auction.accept_offer(request.client_id, request.id, offer.id)
    end

    test "returns :already_accepted when the same offer is accepted twice" do
      request = insert_request!()
      offer = insert_offer!(request, %{status: "accepted"})

      assert {:error, :already_accepted} =
               Auction.accept_offer(request.client_id, request.id, offer.id)
    end
  end
end
