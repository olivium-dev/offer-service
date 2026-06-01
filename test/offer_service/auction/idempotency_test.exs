defmodule OfferService.Auction.IdempotencyTest do
  @moduledoc """
  JEB-49 / AC2 — idempotency contract.

  These tests live at the saga/context layer so they catch idempotency
  bugs even if the controller plug or serialisation ever changes.
  """

  use OfferService.DataCase, async: false

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{AcceptanceIdempotencyKey, AcceptanceOtp, Offer, Request}
  alias OfferService.Clients.{ChatClientMock, NotificationClientMock}
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  # Minimal serializer that mimics the controller's wire shape so the
  # context test exercises the same persistence path the controller uses.
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

  describe "accept_offer_idempotent/6 — first hit" do
    test "executes the saga and persists an idempotency-key row" do
      request = insert_request!()
      offer = insert_offer!(request)
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "thread-fresh"}} end)

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

      assert body["chat_thread_id"] == "thread-fresh"
      assert body["accepted_offer"]["id"] == offer.id

      [row] = Repo.all(AcceptanceIdempotencyKey)
      assert row.idempotency_key == key
      assert row.client_id == request.client_id
      assert row.request_id == request.id
      assert row.offer_id == offer.id
      assert is_map(row.response)
      assert row.response["accepted_offer"]["id"] == offer.id
      assert row.response["chat_thread_id"] == "thread-fresh"
    end
  end

  describe "accept_offer_idempotent/6 — replay" do
    test "same key + same payload returns cached response, no second side-effects" do
      request = insert_request!()
      offer = insert_offer!(request)
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "t-replay"}} end)

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

      # No further ChatClientMock.create_thread expectation set; if the saga
      # runs again Mox will fail verify_on_exit!.
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

      # No duplicate OTP, no duplicate idem row, no duplicate accepted offer.
      assert length(Repo.all(AcceptanceOtp)) == 1
      assert length(Repo.all(AcceptanceIdempotencyKey)) == 1
      assert Repo.get!(Offer, offer.id).status == "accepted"
      assert Repo.get!(Request, request.id).status == "accepted"
    end

    test "side-effects are NOT re-fired on replay" do
      request = insert_request!()
      offer = insert_offer!(request)
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "t-noside"}} end)

      test_pid = self()

      stub(NotificationClientMock, :notify, fn payload ->
        send(test_pid, {:notified, payload})
        :ok
      end)

      key = "idem-noside-" <> Ecto.UUID.generate()

      assert {:ok, :fresh, _} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer.id,
                 [],
                 wire_serializer()
               )

      # Drain first-run notifications.
      _ = drain_messages([], 200)

      assert {:ok, :replay, _} =
               Auction.accept_offer_idempotent(
                 key,
                 request.client_id,
                 request.id,
                 offer.id,
                 [],
                 wire_serializer()
               )

      assert drain_messages([], 200) == []
    end
  end

  describe "accept_offer_idempotent/6 — mismatch" do
    test "same key + different offer_id returns :idempotency_mismatch" do
      request = insert_request!()
      offer_a = insert_offer!(request)
      offer_b = insert_offer!(request)
      expect(ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "t-mm"}} end)

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

      expect(ChatClientMock, :create_thread, 2, fn _ ->
        {:ok, %{thread_id: "t-" <> Ecto.UUID.generate()}}
      end)

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

  defp drain_messages(acc, timeout) do
    receive do
      msg -> drain_messages([msg | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
