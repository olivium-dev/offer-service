import Config

config :offer_service, OfferService.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOSTNAME", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: "offer_service_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # The race-safety property test (acceptance_race_test.exs) fans out up to ~25
  # concurrent Task.async accepts per batch against the shared sandbox; with the
  # default ~50ms queue interval those bursts could exceed pool_size and get
  # dropped ("could not checkout the connection ... request was dropped from
  # queue"), a pre-existing pool-contention flake. Letting contended checkouts
  # wait longer (rather than drop) makes the concurrency stress test
  # deterministic without weakening its one-winner assertion.
  queue_target: 500,
  queue_interval: 2_000

config :offer_service, OfferServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-do-not-use-anywhere-other-than-test-environment",
  server: false

config :offer_service,
  # The shared service does not hardcode the edit cap; the test env pins a
  # concrete `max_edits` so the edit-limit tests have a deterministic ceiling
  # (the production default is `nil` — gateway-supplied).
  max_edits: 2,
  # Enable the S07/N3 force-expire seam in the test env with a known service
  # token so the ServiceAuth gate (flag + X-Service-Auth-Key) can be exercised
  # on both the happy path and the unauthorized/flag-off paths.
  force_expire_seam_enabled: true,
  service_token: "test-service-auth-key-do-not-use-in-prod"

# Oban in :manual test mode — stops the Stager/Peer/Cron plugins from running
# background DB transactions against the Ecto SQL Sandbox pool. Without this,
# those out-of-band transactions intermittently collide with per-test
# connection ownership and produce a cascade of DBConnection.OwnershipError
# failures (a non-deterministic, change-independent suite flake). Jobs can
# still be asserted via Oban.Testing helpers (`assert_enqueued/1`). This is the
# org-standard Oban test posture (elixir-cicd-oban-test-mode).
config :offer_service, Oban, testing: :manual

config :logger, level: :warning
