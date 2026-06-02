defmodule OfferService.Auction.IdempotencyChatGuardTest do
  @moduledoc """
  GUARD: OFFER-IDEMPOTENCY-GUARD.

  Regression coverage proving that the `Idempotency-Key` replay guard covers
  the FULL accept response envelope — specifically the `chat_thread_id` field —
  and that a replay does NOT re-trigger chat-thread creation.

  This guards the invariant the FIX-NOW (OFFER-ATOMICITY) item would depend on:
  if/when chat creation is ever moved post-commit, the cached envelope (including
  whatever `chat_thread_id` was resolved on the first run) must be returned
  verbatim so a client retry never opens a second chat thread.

  Additive-only: a new test module; no production code is touched. It exercises
  the same `Auction.accept_offer_idempotent/6` entry point and `ChatClientMock`
  the existing idempotency suite uses, with explicit assertions on the cached
  `chat_thread_id` and a Mox expectation count that fails if chat creation is
  re-fired on replay.
  """

  use OfferService.DataCase, async: false

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{AcceptanceIdempotencyKey, Offer, Request}
  alias OfferService.Clients.{ChatClientMock, NotificationClientMock}
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  # Mirrors the controller's wire shape so the cached envelope under test is the
  # exact one clients receive.
  defp wire_serializer do
    fn %{
         request: request,
         accepted_offer: offer,
         rejected_offer_ids: rejected_ids,
         otp_code: otp_code,
         thread_id: thread_id
       } ->
      %{
        "request" => %{
          "id" => request.id,
          "status" => request.status,
          "accepted_offer_id" => request.accepted_offer_id,
          "chat_thread_id" => request.chat_thread_id
        },
        "accepted_offer" => %{
          "id" => offer.id,
          "jeeber_id" => offer.jeeber_id,
          "fee_cents" => offer.fee_cents,
          "eta_minutes" => offer.eta_minutes,
          "status" => offer.status
        },
        "rejected_offer_ids" => rejected_ids,
        "chat_thread_id" => thread_id,
        "otp_code" => otp_code
      }
    end
  end

  describe "idempotency cache covers the full accept envelope" do
    test "fresh run caches chat_thread_id at both top-level and request scope" do
      request = insert_request!()
      offer = insert_offer!(request)
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "thread-guard-1"}} end)

      key = "idem-guard-" <> Ecto.UUID.generate()

      assert {:ok, :fresh, body} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer.id,
                 [],
                 wire_serializer()
               )

      assert body["chat_thread_id"] == "thread-guard-1"
      assert body["request"]["chat_thread_id"] == "thread-guard-1"

      # The persisted row must carry the same chat_thread_id so replays are stable.
      [row] = Repo.all(AcceptanceIdempotencyKey)
      assert row.response["chat_thread_id"] == "thread-guard-1"
      assert row.response["request"]["chat_thread_id"] == "thread-guard-1"
    end

    test "replay returns the cached chat_thread_id and does NOT re-create the thread" do
      request = insert_request!()
      offer = insert_offer!(request)

      # Exactly ONE chat-thread creation is permitted across both calls. If the
      # replay re-fires chat creation, verify_on_exit! fails this test because a
      # second, un-expected call would be made.
      expect(ChatClientMock, :create_thread, 1, fn _ ->
        {:ok, %{thread_id: "thread-guard-2"}}
      end)

      key = "idem-guard-replay-" <> Ecto.UUID.generate()

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

      # Byte-identical envelope, including the chat_thread_id, on replay.
      assert cached == first
      assert cached["chat_thread_id"] == "thread-guard-2"

      # State is single-accept; the request still references the original thread.
      assert Repo.get!(Offer, offer.id).status == "accepted"
      reloaded = Repo.get!(Request, request.id)
      assert reloaded.chat_thread_id == "thread-guard-2"
    end
  end
end
