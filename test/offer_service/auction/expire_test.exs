defmodule OfferService.Auction.ExpireTest do
  @moduledoc """
  Unit contract for the S07/N3 force-expire domain flow
  (`OfferService.Auction.force_expire_offer/2` → `Auction.Expire.run/2`).

  Proves the seam:
    * drives a live offer (`submitted` / `pending` / `edited`) to `expired`;
    * writes an `offer_events` audit row (`action: "expire"`);
    * is idempotent-ish on terminal states (re-expire → `:offer_expired`,
      withdrawn → `:offer_withdrawn`, accepted → `:already_accepted`);
    * 404s a phantom offer.

  Authorization is owned by the web pipeline (ServiceAuth), so this domain
  function performs no ownership check — any provided `actor_id` is accepted and
  only recorded on the audit row.
  """
  use OfferService.DataCase, async: true

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, OfferEvent}
  alias OfferService.Repo

  defp jid, do: "s07-jeeber-" <> Integer.to_string(:rand.uniform(9999))

  describe "force_expire_offer/2" do
    test "drives a submitted offer to expired and writes an audit row" do
      request = insert_request!()
      offer = insert_submitted_offer!(request, %{jeeber_id: jid()})

      assert {:ok, %Offer{status: "expired"} = expired} =
               Auction.force_expire_offer("operator-1", offer.id)

      assert expired.id == offer.id
      assert Repo.get!(Offer, offer.id).status == "expired"

      event =
        Repo.one(
          from e in OfferEvent,
            where: e.offer_id == ^offer.id and e.action == "expire"
        )

      assert event
      assert event.from_state == "submitted"
      assert event.to_state == "expired"
      assert event.actor_id == "operator-1"
      assert event.payload["seam"] == "force_expire"
    end

    test "drives a legacy `pending` offer to expired (JEB-47 alias)" do
      request = insert_request!()
      # insert_offer! defaults to status: "pending"
      offer = insert_offer!(request, %{jeeber_id: jid()})

      assert {:ok, %Offer{status: "expired"}} =
               Auction.force_expire_offer("system", offer.id)
    end

    test "drives an edited offer to expired" do
      request = insert_request!()
      offer = insert_offer!(request, %{jeeber_id: jid(), status: "edited", edits_count: 1})

      assert {:ok, %Offer{status: "expired"}} =
               Auction.force_expire_offer("system", offer.id)
    end

    test "re-expiring an already-expired offer returns :offer_expired" do
      request = insert_request!()
      offer = insert_offer!(request, %{jeeber_id: jid(), status: "expired"})

      assert {:error, :offer_expired} = Auction.force_expire_offer("system", offer.id)
    end

    test "expiring a withdrawn offer returns :offer_withdrawn" do
      request = insert_request!()
      offer = insert_offer!(request, %{jeeber_id: jid(), status: "withdrawn"})

      assert {:error, :offer_withdrawn} = Auction.force_expire_offer("system", offer.id)
    end

    test "expiring an accepted offer returns :already_accepted" do
      request = insert_request!()
      offer = insert_offer!(request, %{jeeber_id: jid(), status: "accepted"})

      assert {:error, :already_accepted} = Auction.force_expire_offer("system", offer.id)
    end

    test "404 for a phantom offer id" do
      assert {:error, :not_found} = Auction.force_expire_offer("system", uuid())
    end
  end
end
