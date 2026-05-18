defmodule OfferService.PromEx.OfferMetrics do
  @moduledoc """
  Custom metrics for offer service business operations.
  """
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      # Count offers by status
      counter(
        [:offer_service, :offer, :status, :total],
        event_name: [:offer_service, :offer, :status, :changed],
        description: "Total count of offers by status",
        tag_values: fn %{status: status} ->
          %{status: status}
        end
      ),

      # Time taken for offer acceptance
      distribution(
        [:offer_service, :offer, :acceptance, :duration_milliseconds],
        event_name: [:offer_service, :offer, :accepted],
        description: "Time taken for offer acceptance process",
        measurement: :duration,
        unit: {:native, :millisecond}
      ),

      # Health check metrics
      counter(
        [:offer_service, :health, :check, :total],
        event_name: [:offer_service, :health, :check],
        description: "Health check requests by status",
        tag_values: fn %{endpoint: endpoint, status: status} ->
          %{endpoint: endpoint, status: status}
        end
      )
    ]
  end

  @impl true
  def polling_metrics(_opts) do
    [
      # Current offer counts by status
      last_value(
        [:offer_service, :offers, :active, :count],
        mfa: {OfferService.Metrics, :active_offers_count, []},
        description: "Number of active offers"
      )
    ]
  end
end
