defmodule OfferService.Auction.EditTest do
  use OfferService.DataCase, async: false

  alias OfferService.Auction
  alias OfferService.Auction.{Offer, OfferEvent}

  describe "edit_offer/4 (AC2)" do
    test "first edit: state submitted → edited, edits_count 0 → 1" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:ok, %Offer{} = next} =
               Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_200})

      assert next.status == "edited"
      assert next.edits_count == 1
      assert next.fee_cents == 1_200
      assert next.eta_minutes == 15
    end

    test "second edit succeeds; third edit returns :edit_limit_reached" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:ok, %{edits_count: 1}} =
               Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_100})

      assert {:ok, %{edits_count: 2}} =
               Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_200})

      assert {:error, :edit_limit_reached} =
               Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_300})

      # DB state confirms invariant
      reloaded = Repo.get!(Offer, offer.id)
      assert reloaded.status == "edited"
      assert reloaded.edits_count == 2
      assert reloaded.fee_cents == 1_200
    end

    test "audit log records each edit with before/after payload" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} =
        Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_200, note: "new"})

      events =
        OfferEvent
        |> Repo.all()
        |> Enum.sort_by(& &1.inserted_at)

      assert [%{action: "submit"}, %{action: "edit"} = edit_event] = events
      assert edit_event.from_state == "submitted"
      assert edit_event.to_state == "edited"
      assert edit_event.payload["edits_count"] == 1
      assert edit_event.payload["before"]["fee_cents"] == 1_000
      assert edit_event.payload["after"]["fee_cents"] == 1_200
      assert edit_event.payload["after"]["note"] == "new"
    end

    test "rejects edit by another jeeber (:forbidden)" do
      request = insert_request!()
      owner = uuid()
      attacker = uuid()
      {:ok, offer} = Auction.submit_offer(owner, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      assert {:error, :forbidden} =
               Auction.edit_offer(attacker, request.id, offer.id, %{fee_cents: 1_300})
    end

    test "rejects edit on withdrawn offer (:offer_withdrawn)" do
      request = insert_request!()
      jeeber = uuid()

      {:ok, offer} =
        Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

      {:ok, _} = Auction.withdraw_offer(jeeber, request.id, offer.id)

      assert {:error, :offer_withdrawn} =
               Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_500})
    end

    test "returns :not_found when offer does not belong to request" do
      request_a = insert_request!()
      request_b = insert_request!()
      jeeber = uuid()

      {:ok, offer_on_b} =
        Auction.submit_offer(jeeber, request_b.id, %{fee_cents: 1_000, eta_minutes: 10})

      assert {:error, :not_found} =
               Auction.edit_offer(jeeber, request_a.id, offer_on_b.id, %{fee_cents: 1_500})
    end

    test "emits [:offer, :transition] telemetry on edit (AC5)" do
      ref = make_ref()
      test_pid = self()
      handler_id = "edit-telemetry-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:offer, :transition],
        fn _name, _measurements, metadata, _ ->
          if metadata.action == :edit, do: send(test_pid, {ref, metadata})
        end,
        nil
      )

      try do
        request = insert_request!()
        jeeber = uuid()

        {:ok, offer} =
          Auction.submit_offer(jeeber, request.id, %{fee_cents: 1_000, eta_minutes: 15})

        {:ok, _} = Auction.edit_offer(jeeber, request.id, offer.id, %{fee_cents: 1_200})

        assert_receive {^ref, metadata}, 500
        assert metadata.from == "submitted"
        assert metadata.to == "edited"
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
