import Config

if System.get_env("PHX_SERVER") do
  config :offer_service, OfferServiceWeb.Endpoint, server: true
end

# S07 / N3 force-expire test-seam toggle. Default OFF (set in config.exs): the
# route 404s unless FORCE_EXPIRE_SEAM_ENABLED=true is set at boot. Only override
# the compile-time default when the env var is actually present, so per-env
# config (e.g. config/test.exs enabling the seam) is not clobbered at runtime.
# Even when enabled the route still requires a valid X-Service-Auth-Key matching
# :service_token, so flipping this flag alone does not open an unauthenticated hole.
case System.get_env("FORCE_EXPIRE_SEAM_ENABLED") do
  nil -> :ok
  value -> config :offer_service, force_expire_seam_enabled: value == "true"
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      Expected format: ecto://USER:PASS@HOST/DATABASE
      """

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  ipv6_opts = if System.get_env("ECTO_IPV6") == "true", do: [:inet6], else: []

  config :offer_service, OfferService.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: ipv6_opts

  config :offer_service, OfferServiceWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT") || "4040")
    ],
    secret_key_base: secret_key_base

  # `service_token` guards the internal force-expire test-seam (ServiceAuth).
  config :offer_service,
    service_token:
      System.get_env("INTERNAL_SERVICE_TOKEN") ||
        raise("INTERNAL_SERVICE_TOKEN is required")
end
