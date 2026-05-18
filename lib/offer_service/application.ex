defmodule OfferService.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OfferService.Repo,
      {Phoenix.PubSub, name: OfferService.PubSub},
      # Oban must start after Repo
      {Oban, Application.fetch_env!(:offer_service, Oban)},
      {Task.Supervisor, name: OfferService.TaskSupervisor},
      OfferServiceWeb.Telemetry,
      # PromEx for observability
      OfferService.PromEx,
      # Endpoint last — only serve traffic once workers are up
      OfferServiceWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: OfferService.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    OfferServiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
