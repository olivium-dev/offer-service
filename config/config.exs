import Config

config :offer_service,
  ecto_repos: [OfferService.Repo],
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

config :offer_service, OfferServiceWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: OfferServiceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OfferService.PubSub,
  live_view: [signing_salt: "OfferService"]

config :offer_service,
  chat_client: OfferService.Clients.ChatClient.HTTP,
  notification_client: OfferService.Clients.NotificationClient.HTTP,
  high_fee_threshold_cents: 5_000,
  otp_length: 4

# PromEx configuration
config :offer_service, OfferService.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: [
    host: System.get_env("GRAFANA_HOST", "http://localhost:3000"),
    username: System.get_env("GRAFANA_USERNAME", "admin"),
    password: System.get_env("GRAFANA_PASSWORD", "admin")
  ]

# Oban configuration
config :offer_service, Oban,
  repo: OfferService.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [
      # Example: cleanup old offers every day at 2 AM
      # {"0 2 * * *", OfferService.Workers.CleanupWorker}
    ]}
  ],
  queues: [
    default: 10,
    notifications: 5,
    analytics: 2
  ]

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :trace_id,
    :span_id,
    :accepted_offer_id,
    :rejected_count,
    :reason,
    :status,
    :body
  ]

import_config "#{config_env()}.exs"
