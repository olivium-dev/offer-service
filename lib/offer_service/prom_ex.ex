defmodule OfferService.PromEx do
  @moduledoc """
  PromEx integration for offer-service observability.
  Exposes BEAM, Phoenix, and Ecto telemetry at /metrics endpoint.
  """
  use PromEx, otp_app: :offer_service

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      # Standard plugins
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: OfferServiceWeb.Router},
      {Plugins.Ecto, repos: [OfferService.Repo]},
      Plugins.Oban
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "prometheus_datasource",
      default_selected_interval: "30s"
    ]
  end

  @impl true
  def dashboards do
    [
      # Default dashboards from PromEx
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"}
    ]
  end
end
