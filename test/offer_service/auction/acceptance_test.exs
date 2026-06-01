defmodule OfferService.Auction.AcceptanceTest do
  use OfferService.DataCase, async: false

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

  describe "accept_offer/4 — happy path" do
    test "accepts exactly one offer per request and auto-rejects all others" do
      request = insert_request!()
      target = insert_offer!(request, %{fee_cents: 2_000})
      sibling_a = insert_offer!(request, %{fee_cents: 1_800})
      sibling_b = insert_offer!(request, %{fee_cents: 1_900})

      expect_chat_thread()

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

    test "transitions the request to accepted with a chat thread id and accepted_offer_id" do
      request = insert_request!()
      offer = insert_offer!(request)

      expect_chat_thread("thread-abc-123")

      assert {:ok, %{thread_id: "thread-abc-123"}} =
               Auction.accept_offer(request.client_id, request.id, offer.id)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "accepted"
      assert reloaded.accepted_offer_id == offer.id
      assert reloaded.chat_thread_id == "thread-abc-123"
    end

    test "generates a 4-digit OTP and persists only its hash" do
      request = insert_request!()
      offer = insert_offer!(request)
      expect_chat_thread()

      assert {:ok, %{otp_code: code}} =
               Auction.accept_offer(request.client_id, request.id, offer.id)

      assert byte_size(code) == 4
      assert code =~ ~r/^\d{4}$/

      [otp] = Repo.all(AcceptanceOtp)
      assert otp.offer_id == offer.id
      assert otp.request_id == request.id
      assert otp.code_hash == :crypto.hash(:sha256, code)
      assert otp.code_last2 == String.slice(code, -2, 2)
      assert byte_size(otp.code_last2) == 2
      refute is_nil(otp.expires_at)
    end

    test "fan-out notifications fire for accepted jeeber, rejected jeebers, and client" do
      request = insert_request!()
      target = insert_offer!(request)
      sibling = insert_offer!(request)

      expect_chat_thread()

      test_pid = self()

      stub(NotificationClientMock, :notify, fn payload ->
        send(test_pid, {:notified, payload})
        :ok
      end)

      assert {:ok, _} = Auction.accept_offer(request.client_id, request.id, target.id)

      events = collect_notify_events([], 3, 1_000)

      events_for = fn user_id -> Enum.filter(events, &(&1.user_id == user_id)) end

      [accepted_event] = events_for.(target.jeeber_id)
      assert accepted_event.event == :offer_accepted

      [rejected_event] = events_for.(sibling.jeeber_id)
      assert rejected_event.event == :offer_rejected

      [client_event] = events_for.(request.client_id)
      assert client_event.event == :auction_closed
      assert client_event.payload.rejected_count == 1
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
      assert Repo.all(AcceptanceOtp) == []
    end

    test "accepts a high-fee offer when confirm_high_fee is true" do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 7_500})
      expect_chat_thread()

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
      expect_chat_thread()

      {:ok, _} = Auction.accept_offer(request.client_id, request.id, offer.id)

      second_offer = insert_offer!(request)

      assert {:error, {:already_accepted, winner_user_id}} =
               Auction.accept_offer(request.client_id, request.id, second_offer.id)

      assert winner_user_id == offer.jeeber_id
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

  describe "accept_offer/4 — atomicity" do
    test "rolls back the entire transaction if chat-service fails" do
      request = insert_request!()
      target = insert_offer!(request)
      sibling = insert_offer!(request)

      expect(ChatClientMock, :create_thread, fn _ -> {:error, :timeout} end)

      assert {:error, :chat_service_unavailable} =
               Auction.accept_offer(request.client_id, request.id, target.id)

      # Nothing should have committed
      assert Repo.get!(Offer, target.id).status == "pending"
      assert Repo.get!(Offer, sibling.id).status == "pending"
      assert Repo.get!(Request, request.id).status == "open"
      assert Repo.all(AcceptanceOtp) == []
    end
  end

  # --- helpers -------------------------------------------------------------

  defp expect_chat_thread(thread_id \\ "thread-" <> Ecto.UUID.generate()) do
    expect(ChatClientMock, :create_thread, fn _params ->
      {:ok, %{thread_id: thread_id}}
    end)
  end

  defp collect_notify_events(acc, 0, _timeout), do: Enum.reverse(acc)

  defp collect_notify_events(acc, n, timeout) do
    receive do
      {:notified, payload} -> collect_notify_events([payload | acc], n - 1, timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
