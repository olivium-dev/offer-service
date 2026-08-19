defmodule OfferService.PromEx.OfferMetrics do
  @moduledoc """
  Custom metrics for offer service business operations.
  """
  use PromEx.Plugin

  alias PromEx.MetricTypes.{Event, Polling}

  @active_offers_event [:offer_service, :offers, :active]

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(:offer_service_business_event_metrics, [
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

        # `offer_accept_total{outcome}` counter — product-agnostic name
        # (JEB-1474; any product-specific metric is derived in the gateway).
        counter(
          [:offer, :accept, :total],
          event_name: [:offer, :accept, :outcome],
          description:
            "JEB-49 — total auction-close attempts, tagged by terminal outcome (success or failure cause).",
          measurement: :count,
          tags: [:outcome],
          tag_values: fn meta -> %{outcome: meta[:outcome] || :unknown} end
        ),

        # Per-outcome latency distribution for SLO p99 ≤ 800 ms (NFR-1).
        distribution(
          [:offer, :accept, :duration_ms],
          event_name: [:offer, :accept, :outcome],
          description: "End-to-end offer-accept latency per outcome (JEB-49 NFR-1).",
          measurement: :duration,
          tags: [:outcome],
          tag_values: fn meta -> %{outcome: meta[:outcome] || :unknown} end,
          reporter_options: [buckets: [50, 100, 200, 400, 600, 800, 1_200, 2_000]]
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
      ])
    ]
  end

  @impl true
  def polling_metrics(_opts) do
    [
      Polling.build(
        :offer_service_active_offers_polling_metrics,
        15_000,
        {__MODULE__, :execute_active_offers_count, []},
        [
          last_value(
            [:offer_service, :offers, :active, :count],
            event_name: @active_offers_event,
            measurement: :count,
            description: "Number of active offers"
          )
        ]
      )
    ]
  end

  @doc false
  @spec execute_active_offers_count() :: :ok
  def execute_active_offers_count do
    :telemetry.execute(
      @active_offers_event,
      %{count: OfferService.Metrics.active_offers_count()},
      %{}
    )
  end
end
