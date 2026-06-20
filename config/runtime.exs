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

# `service_token` guards the internal force-expire test-seam (ServiceAuth plug).
# It used to be wired ONLY inside the :prod block below, which meant a local/dev
# bring-up (MIX_ENV=dev) that enabled the seam flag had a `nil` :service_token and
# the plug failed closed (401) on every call. Honor INTERNAL_SERVICE_TOKEN for
# non-prod (dev) bring-ups so the seam can be exercised without MIX_ENV=prod.
#
# `:test` and `:prod` are EXCLUDED on purpose:
#   - `:test` keeps its own compile-time token from config/test.exs.
#   - `:prod` is wired (and hard-fails on a missing token) by the :prod block
#     below, which is the single authoritative writer of :service_token in prod.
#     Excluding prod here makes that guarantee independent of block ordering — a
#     future reorder cannot route prod through this softer branch.
#
# Default-off is preserved: with no env var set (or set to ""), the token stays
# unconfigured and the plug still fails closed. An empty string is treated as
# unset; only a non-empty value configures the token.
if config_env() not in [:test, :prod] do
  case System.get_env("INTERNAL_SERVICE_TOKEN") do
    token when is_binary(token) and token != "" ->
      config :offer_service, service_token: token

    _ ->
      :ok
  end
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
  # Authoritative writer of :service_token in prod; raises when unset so prod
  # refuses to boot without a token.
  #
  # TODO(fast-follow): `||` only catches nil/false, so INTERNAL_SERVICE_TOKEN=""
  # (or whitespace-only) is truthy and boots prod with an empty/blank token. Not
  # exploitable — ServiceAuth fails closed on a blank configured token (401) — but
  # it boots a permanently-unreachable seam instead of failing loudly. Tighten to
  # reject blank: `case System.get_env(...) do t when is_binary(t) and
  # String.trim(t) != "" -> t; _ -> raise(...) end`. Kept byte-compatible here to
  # keep this PR minimal; see PR #23 review threads.
  config :offer_service,
    service_token:
      System.get_env("INTERNAL_SERVICE_TOKEN") ||
        raise("INTERNAL_SERVICE_TOKEN is required")
end
