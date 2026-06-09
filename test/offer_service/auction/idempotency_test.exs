defmodule OfferService.Auction.IdempotencyTest do
  @moduledoc """
  JEB-49 / AC2 — idempotency contract.

  These tests live at the saga/context layer so they catch idempotency
  bugs even if the controller plug or serialisation ever changes.
  """

  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{AcceptanceIdempotencyKey, Offer, Request}
  alias OfferService.Repo

  # Minimal serializer that mimics the controller's wire shape so the
  # context test exercises the same persistence path the controller uses.
  # JEB-1474: the saga result is ONLY the generic transition outcome — no OTP,
  # no chat-thread linkage (those are gateway-owned).
  defp wire_serializer do
    fn %{
         request: request,
         accepted_offer: offer,
         rejected_offer_ids: rejected_ids
       } ->
      %{
        "request" => %{
          "id" => request.id,
          "status" => request.status,
          "accepted_offer_id" => request.accepted_offer_id
        },
        "accepted_offer" => %{
          "id" => offer.id,
          "actor_id" => offer.actor_id,
          "fee_cents" => offer.fee_cents,
          "eta_minutes" => offer.eta_minutes,
          "status" => offer.status
        },
        "rejected_offer_ids" => rejected_ids
      }
    end
  end

  describe "accept_offer_idempotent/6 — first hit" do
    test "executes the saga and persists an idempotency-key row" do
      request = insert_request!()
      offer = insert_offer!(request)

      key = "idem-fresh-" <> Ecto.UUID.generate()

      assert {:ok, :fresh, body} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer.id,
                 [],
                 wire_serializer()
               )

      assert body["accepted_offer"]["id"] == offer.id

      [row] = Repo.all(AcceptanceIdempotencyKey)
      assert row.idempotency_key == key
      assert row.client_id == request.client_id
      assert row.request_id == request.id
      assert row.offer_id == offer.id
      assert is_map(row.response)
      assert row.response["accepted_offer"]["id"] == offer.id
    end
  end

  describe "accept_offer_idempotent/6 — replay" do
    test "same key + same payload returns cached response, saga not re-run" do
      request = insert_request!()
      offer = insert_offer!(request)

      key = "idem-replay-" <> Ecto.UUID.generate()

      assert {:ok, :fresh, first} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer.id,
                 [],
                 wire_serializer()
               )

      assert {:ok, :replay, cached} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer.id,
                 [],
                 wire_serializer()
               )

      assert cached == first

      # No duplicate idem row, no duplicate accepted offer — the single-winner
      # transition is applied at most once.
      assert length(Repo.all(AcceptanceIdempotencyKey)) == 1
      assert Repo.get!(Offer, offer.id).status == "accepted"
      assert Repo.get!(Request, request.id).status == "accepted"
    end
  end

  describe "accept_offer_idempotent/6 — mismatch" do
    test "same key + different offer_id returns :idempotency_mismatch" do
      request = insert_request!()
      offer_a = insert_offer!(request)
      offer_b = insert_offer!(request)

      key = "idem-mm-" <> Ecto.UUID.generate()

      assert {:ok, :fresh, _} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer_a.id,
                 [],
                 wire_serializer()
               )

      assert {:error, :idempotency_mismatch} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer_b.id,
                 [],
                 wire_serializer()
               )
    end

    test "different client reusing the same key is treated as a fresh attempt" do
      request_a = insert_request!()
      offer_a = insert_offer!(request_a)

      request_b = insert_request!()
      offer_b = insert_offer!(request_b)

      key = "shared-key-" <> Ecto.UUID.generate()

      assert {:ok, :fresh, _} =
               Auction.accept_offer_idempotent(
                 key,
                 request_a.client_id,
                 request_a.id,
                 offer_a.id,
                 [],
                 wire_serializer()
               )

      assert {:ok, :fresh, _} =
               Auction.accept_offer_idempotent(
                 key,
                 request_b.client_id,
                 request_b.id,
                 offer_b.id,
                 [],
                 wire_serializer()
               )
    end
  end
end
