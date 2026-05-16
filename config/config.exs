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
