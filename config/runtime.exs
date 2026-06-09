import Config

if System.get_env("PHX_SERVER") do
  config :offer_service, OfferServiceWeb.Endpoint, server: true
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

  config :offer_service,
    notification_service_url:
      System.get_env("NOTIFICATION_SERVICE_URL") ||
        raise("NOTIFICATION_SERVICE_URL is required"),
    service_token:
      System.get_env("INTERNAL_SERVICE_TOKEN") ||
        raise("INTERNAL_SERVICE_TOKEN is required")
end
