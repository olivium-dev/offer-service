defmodule OfferService.Auction.OpaqueIdentityWideningTest do
  @moduledoc """
  S07 regression coverage for the uuid -> text widening of the four *external
  opaque identity* columns (`requests.client_id`, `offers.jeeber_id`,
  `offer_events.actor_id`, `acceptance_idempotency_keys.client_id`).

  ## What was broken

  The Jeeb gateway forwards the user's JWT `sub` (e.g. `s07-sami-client`,
  `s07-kamal-jeeber`) as `x-user-id`. Those subs are NOT uuids. While the
  identity columns were typed `uuid`, every INSERT carrying a non-uuid sub
  raised Postgres `22P02 invalid input syntax for type uuid` and surfaced as a
  500:

    * `POST /api/v1/requests` (OS-1 mirror) — 500 on `client_id`.
    * `POST /requests/:id/offers` (Submit, the S07 "Kamal submits a bid"
      step H2) — 500 on `offers.jeeber_id` (+ `offer_events.actor_id`),
      which gated the ENTIRE auction saga: no offer => no offer to accept.
    * Accept idempotency INSERT — 500 on
      `acceptance_idempotency_keys.client_id`.

  These tests drive the REAL Submit/Accept/Idempotency code against the DB
  sandbox with non-uuid identities and assert success. Only the cross-service
  NotificationClient is Mox-stubbed, exactly as the existing acceptance tests
  do. offer-service holds NO chat client (fix C / no-coupling LAW), so
  `thread_id` is always nil.
  """
  use OfferService.DataCase, async: false

  import Mox

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, OfferEvent, Request}
  alias OfferService.Clients.NotificationClientMock
  alias OfferService.Repo

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(NotificationClientMock, :notify, fn _ -> :ok end)
    :ok
  end

  # The two S07 personas, verbatim from data/scenarios/scenario-S07.json — both
  # are opaque, non-uuid subs.
  @sami "s07-sami-client"
  @kamal "s07-kamal-jeeber"
  @rana "s07-rana-jeeber"

  describe "OS-1 request mirror with a non-uuid client_id" do
    test "POST mirror persists the opaque sub verbatim (was 500)" do
      request_id = Ecto.UUID.generate()

      assert {:ok, :created, %Request{} = req} =
               Auction.upsert_request(%{
                 "request_id" => request_id,
                 "client_id" => @sami,
                 "status" => "open"
               })

      assert req.id == request_id
      assert req.client_id == @sami

      # Re-read from the DB to prove it round-trips through Postgres `text`.
      assert Repo.get!(Request, request_id).client_id == @sami
    end

    test "uuid client_id still works (backward compatible)" do
      request_id = Ecto.UUID.generate()
      uuid_client = Ecto.UUID.generate()

      assert {:ok, :created, %Request{client_id: ^uuid_client}} =
               Auction.upsert_request(%{
                 "request_id" => request_id,
                 "client_id" => uuid_client
               })
    end
  end

  describe "Submit with a non-uuid jeeber_id" do
    test "an offer with an opaque Jeeber sub is created + audited (was 500)" do
      request = mirror_request!(@sami)

      assert {:ok, %Offer{} = offer} =
               Auction.submit_offer(@kamal, request.id, %{
                 "fee_cents" => 1_500,
                 "eta_minutes" => 25,
                 "note" => "on it"
               })

      assert offer.jeeber_id == @kamal
      assert offer.status == "submitted"

      # The append-only audit row also carries the opaque sub in actor_id.
      event = Repo.get_by!(OfferEvent, offer_id: offer.id, action: "submit")
      assert event.actor_id == @kamal
    end
  end

  describe "full submit -> accept saga with non-uuid identities (S07 happy path)" do
    test "the CLIENT (Sami) accepts Kamal's offer; Rana is superseded; replay is stable" do
      request = mirror_request!(@sami)

      {:ok, kamal_offer} =
        Auction.submit_offer(@kamal, request.id, %{"fee_cents" => 2_000, "eta_minutes" => 20})

      {:ok, _rana_offer} =
        Auction.submit_offer(@rana, request.id, %{"fee_cents" => 1_800, "eta_minutes" => 30})

      key = "idem-" <> Ecto.UUID.generate()

      # Offer-scoped accept by the request-owning CLIENT (Sami), opaque sub.
      # The Client accepts a Jeeber's bid — that is the S07 auction-close rule.
      assert {:ok, :fresh, first} =
               Auction.accept_offer_by_id(key, @sami, kamal_offer.id, [], &serialize/1)

      reloaded = Repo.get!(Request, request.id)
      assert reloaded.status == "accepted"
      assert reloaded.accepted_offer_id == kamal_offer.id
      assert Repo.get!(Offer, kamal_offer.id).status == "accepted"

      # Idempotent replay: same key + same (actor, offer). The idempotency row
      # (client_id = opaque @sami) is read back and the saga is NOT re-run —
      # no second chat-thread expectation is set, so verify_on_exit! would flag
      # a duplicate side effect.
      assert {:ok, :replay, second} =
               Auction.accept_offer_by_id(key, @sami, kamal_offer.id, [], &serialize/1)

      assert first["otp_code"] == second["otp_code"]
      assert first["accepted_offer"]["id"] == second["accepted_offer"]["id"]
    end

    test "ownership guard rejects a Jeeber accepting (only the request CLIENT may accept)" do
      request = mirror_request!(@sami)
      {:ok, kamal_offer} = Auction.submit_offer(@kamal, request.id, %{"fee_cents" => 2_000, "eta_minutes" => 20})

      # Kamal (the offer's own Jeeber, opaque sub) is NOT the request owner ->
      # 403, saga never entered. A Jeeber cannot accept its own bid.
      assert {:error, :forbidden} =
               Auction.accept_offer_by_id("idem-" <> Ecto.UUID.generate(), @kamal, kamal_offer.id)

      # Likewise any other Jeeber is forbidden.
      assert {:error, :forbidden} =
               Auction.accept_offer_by_id("idem-" <> Ecto.UUID.generate(), @rana, kamal_offer.id)

      assert Repo.get!(Offer, kamal_offer.id).status == "submitted"
      assert Repo.get!(Request, request.id).status == "open"
    end
  end

  # --- helpers -------------------------------------------------------------

  defp mirror_request!(client_id) do
    {:ok, _mode, request} =
      Auction.upsert_request(%{
        "request_id" => Ecto.UUID.generate(),
        "client_id" => client_id,
        "status" => "open"
      })

    request
  end

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
        "accepted_offer_id" => request.accepted_offer_id
      },
      "accepted_offer" => %{"id" => offer.id, "status" => offer.status},
      "rejected_offer_ids" => rejected_ids,
      "chat_thread_id" => thread_id,
      "otp_code" => otp_code
    }
  end
end
