import Config

config :offer_service, OfferService.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOSTNAME", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: "offer_service_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :offer_service, OfferServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-do-not-use-anywhere-other-than-test-environment",
  server: false

config :offer_service,
  chat_client: OfferService.Clients.ChatClientMock,
  notification_client: OfferService.Clients.NotificationClientMock,
  fanout_strategy: :sync

config :logger, level: :warning
