import Config

config :offer_service, OfferServiceWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
