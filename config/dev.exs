import Config

config :offer_service, OfferService.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOSTNAME", "localhost"),
  database: System.get_env("DB_NAME", "offer_service_dev"),
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :offer_service, OfferServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  check_origin: false,
  debug_errors: true,
  code_reloader: true,
  secret_key_base: "dev-only-secret-not-for-production-please-do-not-use-this-key-ever"

config :offer_service,
  chat_service_url: System.get_env("CHAT_SERVICE_URL", "http://localhost:5000"),
  notification_service_url: System.get_env("NOTIFICATION_SERVICE_URL", "http://localhost:5001")

config :logger, level: :debug
