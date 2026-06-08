defmodule OfferService.Auction.RequestBridgeTest do
  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{Acceptance, Offer, Request}
  alias OfferService.Repo

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "upsert/1 — request-bridge" do
    test "creates an open request from a gateway-supplied id" do
      id = uuid()
      client_id = uuid()

      assert {:ok, :created, %Request{} = req} =
               Auction.upsert_request(%{"request_id" => id, "client_id" => client_id})

      assert req.id == id
      assert req.client_id == client_id
      assert req.status == "open"
      assert Repo.get(Request, id)
    end

    test "accepts `id` as an alias for `request_id`" do
      id = uuid()

      assert {:ok, :created, %Request{id: ^id}} =
               Auction.upsert_request(%{"id" => id, "client_id" => uuid()})
    end

    test "is idempotent — a replay returns :exists and does not duplicate" do
      id = uuid()
      client_id = uuid()
      attrs = %{"request_id" => id, "client_id" => client_id}

      assert {:ok, :created, _} = Auction.upsert_request(attrs)
      assert {:ok, :exists, %Request{id: ^id}} = Auction.upsert_request(attrs)

      assert Repo.aggregate(from(r in Request, where: r.id == ^id), :count) == 1
    end

    test "a replay never resets lifecycle state set by the accept saga" do
      id = uuid()
      client_id = uuid()
      assert {:ok, :created, _} = Auction.upsert_request(%{"request_id" => id, "client_id" => client_id})

      # Drive the request to `accepted` through the real saga.
      offer = insert_offer!(%Request{id: id, client_id: client_id})
      stub(OfferService.Clients.NotificationClientMock, :notify, fn _ -> :ok end)
      expect(OfferService.Clients.ChatClientMock, :create_thread, fn _ -> {:ok, %{thread_id: "t-1"}} end)
      assert {:ok, %{}} = Acceptance.run(client_id, id, offer.id)

      accepted = Repo.get!(Request, id)
      assert accepted.status == "accepted"
      refute is_nil(accepted.accepted_offer_id)

      # A late, best-effort re-mirror must NOT clobber the accepted state.
      assert {:ok, :exists, %Request{} = after_remirror} =
               Auction.upsert_request(%{"request_id" => id, "client_id" => client_id})

      assert after_remirror.status == "accepted"
      assert after_remirror.accepted_offer_id == accepted.accepted_offer_id
    end

    test "rejects a missing id with :invalid_id" do
      assert {:error, :invalid_id} = Auction.upsert_request(%{"client_id" => uuid()})
    end

    test "rejects a non-UUID id with :invalid_id" do
      assert {:error, :invalid_id} =
               Auction.upsert_request(%{"request_id" => "not-a-uuid", "client_id" => uuid()})
    end

    test "rejects a missing client_id with a changeset error" do
      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               Auction.upsert_request(%{"request_id" => uuid()})

      assert {"can't be blank", _} = cs.errors[:client_id]
    end

    test "a submitted offer resolves against a bridged request (closes the 500)" do
      id = uuid()
      client_id = uuid()
      jeeber = uuid()
      assert {:ok, :created, _} = Auction.upsert_request(%{"request_id" => id, "client_id" => client_id})

      assert {:ok, %Offer{} = offer} =
               Auction.submit_offer(jeeber, id, %{fee_cents: 1_500, eta_minutes: 20})

      assert offer.request_id == id
      assert offer.status == "submitted"
    end
  end
end
