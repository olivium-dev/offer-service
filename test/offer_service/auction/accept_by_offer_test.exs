defmodule OfferService.Auction.AcceptByOfferTest do
  @moduledoc """
  Offer-scoped accept (S07 / OS-4): `Auction.accept_offer_by_id/5`.

  S07 business rule: a CLIENT creates a delivery request; JEEBERS submit offers
  (bids); the CLIENT accepts one offer to close the auction. The authorized
  acceptor on this route is therefore the request's CLIENT
  (`request.client_id == actor_id`) — NOT the offer's Jeeber.

  These tests prove the offer→request resolution and that authorization +
  every downstream negative/success is produced verbatim by the existing
  idempotent accept saga. No mocking of the saga itself — they hit the real DB
  sandbox and the real `Acceptance`/`Idempotency` code; only the cross-service
  NotificationClient is Mox-stubbed, exactly as the request-scoped acceptance
  tests do. offer-service holds NO chat client (fix C / no-coupling LAW), so
  chat provisioning is owned by the gateway BFF and `thread_id` is always nil.

  Actor ids use NON-UUID opaque identifiers (the gateway JWT `sub`, e.g.
  `s07-sami-client-9558`) to prove the a3 uuid->text column widening holds and
  that authorization works on opaque string identity, not uuid.
  """
  use OfferService.DataCase, async: false

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, Request}
  alias OfferService.Clients.NotificationClientMock
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  describe "accept_offer_by_id/5 — happy path (the request CLIENT accepts a Jeeber's offer)" do
    test "the request's client accepts a Jeeber offer by offer id; auction closes" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      target = insert_offer!(request, %{jeeber_id: jeeber_id("kamal"), fee_cents: 2_000})
      sibling = insert_offer!(request, %{jeeber_id: jeeber_id("rana"), fee_cents: 1_800})

      assert {:ok, :fresh, body} =
               Auction.accept_offer_by_id(idem_key(), client, target.id)

      assert is_map(body)

      # Saga ran: exactly one accepted, the sibling auto-rejected, request closed.
      assert Repo.get!(Offer, target.id).status == "accepted"
      assert Repo.get!(Offer, sibling.id).status == "rejected"

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "accepted"
      assert reloaded.accepted_offer_id == target.id
    end

    test "idempotent replay returns the same body with mode :replay" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      target = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      key = idem_key()

      # Serialize to the wire shape (as the controller does) so the comparison
      # is over the persisted JSON envelope, not raw Ecto structs with unloaded
      # association placeholders.
      assert {:ok, :fresh, first} =
               Auction.accept_offer_by_id(key, client, target.id, [], &serialize/1)

      # Same key + same (actor, offer) => replay, saga is NOT re-run.
      assert {:ok, :replay, second} =
               Auction.accept_offer_by_id(key, client, target.id, [], &serialize/1)

      assert first["otp_code"] == second["otp_code"]
      assert first["accepted_offer"]["id"] == second["accepted_offer"]["id"]
      assert first["request"]["status"] == "accepted"
      assert second["request"]["status"] == "accepted"
    end
  end

  describe "accept_offer_by_id/5 — authorization is request-CLIENT-scoped (403 non-owner)" do
    test "the offer's OWN Jeeber is :forbidden — a Jeeber cannot accept its own bid" do
      request = insert_request!(%{client_id: client_id("sami")})
      target = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      # The Jeeber owns the offer but does NOT own the request: on this route the
      # request's Client is the only authorized acceptor. Saga must never close.
      assert {:error, :forbidden} =
               Auction.accept_offer_by_id(idem_key(), target.jeeber_id, target.id)

      assert Repo.get!(Offer, target.id).status == "pending"
      assert Repo.get!(Request, request.id).status == "open"
    end

    test "a DIFFERENT client (not the request owner) is :forbidden and never enters the saga" do
      request = insert_request!(%{client_id: client_id("sami")})
      target = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})
      stranger = client_id("intruder")

      # The saga must never run.
      assert {:error, :forbidden} =
               Auction.accept_offer_by_id(idem_key(), stranger, target.id)

      assert Repo.get!(Offer, target.id).status == "pending"
      assert Repo.get!(Request, request.id).status == "open"
    end
  end

  describe "accept_offer_by_id/5 — negatives forwarded verbatim from the saga" do
    test "phantom offer id => :not_found (404 class), non-uuid actor" do
      assert {:error, :not_found} =
               Auction.accept_offer_by_id(idem_key(), client_id("sami"), uuid())
    end

    test "request already accepted by the client => {:already_accepted, winner} (409 class)" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      first = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      assert {:ok, :fresh, _} =
               Auction.accept_offer_by_id(idem_key(), client, first.id)

      second = insert_offer!(request, %{jeeber_id: jeeber_id("rana")})

      # A fresh (different idem key) accept on the now-closed request returns the
      # winning Jeeber so the caller can render {error, already_accepted, winner}.
      assert {:error, {:already_accepted, winner}} =
               Auction.accept_offer_by_id(idem_key(), client, second.id)

      assert winner == first.jeeber_id
    end

    test "request expired => :request_expired (410 class)" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client, status: "expired"})
      offer = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})

      assert {:error, :request_expired} =
               Auction.accept_offer_by_id(idem_key(), client, offer.id)
    end

    test "withdrawn offer => :offer_withdrawn (410 class)" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})

      offer =
        insert_offer!(request, %{jeeber_id: jeeber_id("kamal"), status: "withdrawn"})

      assert {:error, :offer_withdrawn} =
               Auction.accept_offer_by_id(idem_key(), client, offer.id)

      assert Repo.get!(Request, request.id).status == "open"
    end

    test "idempotency-key mismatch (same key, different offer) => :idempotency_mismatch (422 class)" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      a = insert_offer!(request, %{jeeber_id: jeeber_id("kamal")})
      b = insert_offer!(request, %{jeeber_id: jeeber_id("rana")})

      key = idem_key()

      assert {:ok, :fresh, _} = Auction.accept_offer_by_id(key, client, a.id)

      # Same key, divergent payload fingerprint (different offer id) -> rejected.
      assert {:error, :idempotency_mismatch} =
               Auction.accept_offer_by_id(key, client, b.id)
    end

    test "high-fee offer requires confirmation; confirm_high_fee opt is honored" do
      client = client_id("sami")
      request = insert_request!(%{client_id: client})
      offer = insert_offer!(request, %{jeeber_id: jeeber_id("kamal"), fee_cents: 7_500})

      assert {:error, :high_fee_confirmation_required} =
               Auction.accept_offer_by_id(idem_key(), client, offer.id)

      assert {:ok, :fresh, _} =
               Auction.accept_offer_by_id(
                 idem_key(),
                 client,
                 offer.id,
                 confirm_high_fee: true
               )
    end
  end

  # --- helpers -------------------------------------------------------------

  defp idem_key, do: "idem-" <> Ecto.UUID.generate()

  # Non-uuid opaque identities (gateway JWT `sub`), proving the a3 uuid->text
  # widening: authorization keys off string identity, not uuid.
  defp client_id(who), do: "s07-#{who}-client-" <> Integer.to_string(:rand.uniform(9999))
  defp jeeber_id(who), do: "s07-#{who}-jeeber-" <> Integer.to_string(:rand.uniform(9999))

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
end
