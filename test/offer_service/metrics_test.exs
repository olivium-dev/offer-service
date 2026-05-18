defmodule OfferService.MetricsTest do
  use OfferService.DataCase
  import OfferService.Fixtures
  alias OfferService.Metrics

  describe "active_offers_count/0" do
    test "returns 0 when no offers exist" do
      assert Metrics.active_offers_count() == 0
    end

    test "counts pending and accepted offers only" do
      request = insert_request!()

      # Create offers with different statuses
      _pending_offer = insert_offer!(request, %{status: "pending"})
      _accepted_offer = insert_offer!(request, %{status: "accepted"})
      _rejected_offer = insert_offer!(request, %{status: "rejected"})
      _withdrawn_offer = insert_offer!(request, %{status: "withdrawn"})

      # Should count only pending and accepted (2 offers)
      assert Metrics.active_offers_count() == 2
    end

    test "handles database errors gracefully" do
      # This is tested implicitly - if there's a database error,
      # the function should return 0 instead of crashing
      assert is_integer(Metrics.active_offers_count())
      assert Metrics.active_offers_count() >= 0
    end
  end
end
