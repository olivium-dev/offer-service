defmodule OfferService.Auction.SubmitTest do
  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, OfferEvent}

  describe "submit_offer/3 (AC1)" do
    test "AC1: state=submitted, edits_count=0" do
      request = insert_request!()
      jeeber = uuid()

      assert {:ok, %Offer{} = offer} =
               Auction.submit_offer(jeeber, request.id, %{
                 fee_cents: 2_500,
                 eta_minutes: 30,
                 note: "ready in 30"
               })

      assert offer.status == "submitted"
      assert offer.edits_count == 0
      assert offer.jeeber_id == jeeber
      assert offer.request_id == request.id
      assert offer.fee_cents == 2_500
      assert offer.eta_minutes == 30
      assert offer.note == "ready in 30"
    end

    test "writes an offer_events audit row with action=submit and from_state=nil" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_200, eta_minutes: 20})

      [event] = Repo.all(OfferEvent)
      assert event.offer_id == offer.id
      assert event.request_id == request.id
      assert event.actor_id == jeeber
      assert event.action == "submit"
      assert event.from_state == nil
      assert event.to_state == "submitted"
      assert event.payload["fee_cents"] == 1_200
      assert event.payload["eta_minutes"] == 20
    end

    test "rejects fee_cents < 100" do
      request = insert_request!()

      assert {:error, %Ecto.Changeset{}} =
               Auction.submit_offer(uuid(), request.id, %{fee_cents: 50, eta_minutes: 10})
    end

    test "rejects eta_minutes <= 0" do
      request = insert_request!()

      assert {:error, %Ecto.Changeset{}} =
               Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 0})
    end

    test "rejects re-submit by same jeeber for same request (:already_submitted)" do
      request = insert_request!()
      jeeber = uuid()
      attrs = %{fee_cents: 1_500, eta_minutes: 20}

      assert {:ok, _} = Auction.submit_offer(jeeber, request.id, attrs)

      assert {:error, :already_submitted} =
               Auction.submit_offer(jeeber, request.id, attrs)
    end

    test "rejects submit when request does not exist (:not_found)" do
      assert {:error, :not_found} =
               Auction.submit_offer(uuid(), uuid(), %{fee_cents: 1_000, eta_minutes: 10})
    end

    test "rejects submit when request is not open (:request_not_open)" do
      request = insert_request!(%{status: "accepted"})

      assert {:error, :request_not_open} =
               Auction.submit_offer(uuid(), request.id, %{fee_cents: 1_000, eta_minutes: 10})
    end

    test "emits [:offer, :transition] telemetry (AC5)" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "submit-telemetry-#{System.unique_integer()}",
        [:offer, :transition],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {ref, measurements, metadata})
        end,
        nil
      )

      try do
        request = insert_request!()
        jeeber = uuid()
        {:ok, _} = Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 10})

        assert_receive {^ref, measurements, metadata}, 500
        assert measurements.count == 1
        assert metadata.action == :submit
        assert metadata.from == nil
        assert metadata.to == "submitted"
        assert metadata.actor_id == jeeber
        assert metadata.request_id == request.id
      after
        :telemetry.detach("submit-telemetry-#{System.unique_integer()}")
      end
    end
  end
end
