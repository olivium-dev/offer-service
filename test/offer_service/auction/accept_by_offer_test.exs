defmodule OfferService.Auction.AcceptByOfferTest do
  @moduledoc """
  Offer-scoped accept (S07 / OS-4): `Auction.accept_offer_by_id/5`.

  Proves the offer→request resolution + OFFER-ownership gate, and that every
  downstream negative/success is produced verbatim by the existing idempotent
  accept saga. No mocking of the saga itself — these hit the real DB sandbox
  and the real `Acceptance`/`Idempotency` code; only the cross-service
  ChatClient/NotificationClient are Mox-stubbed exactly as the request-scoped
  acceptance tests do.
  """
  use OfferService.DataCase, async: false

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, Request}
  alias OfferService.Clients.{ChatClientMock, NotificationClientMock}
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  describe "accept_offer_by_id/5 — happy path (offer-owner accepts)" do
    test "the offer's Jeeber accepts by offer id without supplying request_id" do
      request = insert_request!()
      target = insert_offer!(request, %{fee_cents: 2_000})
      sibling = insert_offer!(request, %{fee_cents: 1_800})

      expect_chat_thread()

      assert {:ok, :fresh, body} =
               Auction.accept_offer_by_id(idem_key(), target.jeeber_id, target.id)

      assert is_map(body)

      # Saga ran: exactly one accepted, the sibling auto-rejected, request closed.
      assert Repo.get!(Offer, target.id).status == "accepted"
      assert Repo.get!(Offer, sibling.id).status == "rejected"

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "accepted"
      assert reloaded.accepted_offer_id == target.id
    end

    test "idempotent replay returns the same body with mode :replay" do
      request = insert_request!()
      target = insert_offer!(request)

      expect_chat_thread()

      key = idem_key()

      # Serialize to the wire shape (as the controller does) so the comparison
      # is over the persisted JSON envelope, not raw Ecto structs with unloaded
      # association placeholders.
      assert {:ok, :fresh, first} =
               Auction.accept_offer_by_id(key, target.jeeber_id, target.id, [], &serialize/1)

      # Same key + same (actor, offer) => replay, saga is NOT re-run (no second
      # chat-thread expectation set; verify_on_exit! would flag a 2nd call).
      assert {:ok, :replay, second} =
               Auction.accept_offer_by_id(key, target.jeeber_id, target.id, [], &serialize/1)

      assert first["otp_code"] == second["otp_code"]
      assert first["accepted_offer"]["id"] == second["accepted_offer"]["id"]
      assert first["request"]["status"] == "accepted"
      assert second["request"]["status"] == "accepted"
    end
  end

  describe "accept_offer_by_id/5 — authorization is OFFER-scoped" do
    test "a different Jeeber (not the offer owner) gets :forbidden and never enters the saga" do
      request = insert_request!()
      target = insert_offer!(request)
      not_the_owner = uuid()

      # No chat-thread expected: the saga must never run.
      assert {:error, :forbidden} =
               Auction.accept_offer_by_id(idem_key(), not_the_owner, target.id)

      assert Repo.get!(Offer, target.id).status == "pending"
      assert Repo.get!(Request, request.id).status == "open"
    end

    test "even the request's own client is :forbidden on the offer-scoped path (offer-owner only)" do
      request = insert_request!()
      target = insert_offer!(request)

      # The request client owns the request but NOT the offer — on this route the
      # offer's Jeeber is the only authorized acceptor.
      assert {:error, :forbidden} =
               Auction.accept_offer_by_id(idem_key(), request.client_id, target.id)

      assert Repo.get!(Offer, target.id).status == "pending"
      assert Repo.get!(Request, request.id).status == "open"
    end
  end

  describe "accept_offer_by_id/5 — negatives forwarded verbatim from the saga" do
    test "phantom offer id => :not_found" do
      assert {:error, :not_found} =
               Auction.accept_offer_by_id(idem_key(), uuid(), uuid())
    end

    test "request already accepted => {:already_accepted, winner} (409 class)" do
      request = insert_request!()
      first = insert_offer!(request)
      expect_chat_thread()

      assert {:ok, :fresh, _} =
               Auction.accept_offer_by_id(idem_key(), first.jeeber_id, first.id)

      second = insert_offer!(request)

      assert {:error, {:already_accepted, winner}} =
               Auction.accept_offer_by_id(idem_key(), second.jeeber_id, second.id)

      assert winner == first.jeeber_id
    end

    test "request expired => :request_expired (410 class)" do
      request = insert_request!(%{status: "expired"})
      offer = insert_offer!(request)

      assert {:error, :request_expired} =
               Auction.accept_offer_by_id(idem_key(), offer.jeeber_id, offer.id)
    end

    test "high-fee offer requires confirmation; confirm_high_fee opt is honored" do
      request = insert_request!()
      offer = insert_offer!(request, %{fee_cents: 7_500})

      assert {:error, :high_fee_confirmation_required} =
               Auction.accept_offer_by_id(idem_key(), offer.jeeber_id, offer.id)

      expect_chat_thread()

      assert {:ok, :fresh, _} =
               Auction.accept_offer_by_id(
                 idem_key(),
                 offer.jeeber_id,
                 offer.id,
                 confirm_high_fee: true
               )
    end
  end

  # --- helpers -------------------------------------------------------------

  defp idem_key, do: "idem-" <> Ecto.UUID.generate()

  # Mirrors the controller's serialize_accept/1 but emits STRING keys, so the
  # fresh response and the JSON-round-tripped replay response are directly
  # comparable (the Idempotency store persists and re-decodes as JSON).
  defp serialize(%{
         request: request,
         accepted_offer: offer,
         rejected_offer_ids: rejected_ids,
         otp_code: otp_code,
         thread_id: thread_id
       }) do
    %{
      "request" => %{
        "id" => request.id,
        "status" => request.status,
        "accepted_offer_id" => request.accepted_offer_id,
        "chat_thread_id" => request.chat_thread_id
      },
      "accepted_offer" => %{
        "id" => offer.id,
        "status" => offer.status
      },
      "rejected_offer_ids" => rejected_ids,
      "chat_thread_id" => thread_id,
      "otp_code" => otp_code
    }
  end

  defp expect_chat_thread(thread_id \\ "thread-" <> Ecto.UUID.generate()) do
    expect(ChatClientMock, :create_thread, fn _params ->
      {:ok, %{thread_id: thread_id}}
    end)
  end
end
