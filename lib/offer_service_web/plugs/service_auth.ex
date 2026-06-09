defmodule OfferServiceWeb.Plugs.ServiceAuth do
  @moduledoc """
  Guards privileged internal/test-only routes (e.g. the S07/N3 force-expire
  seam) behind a feature flag **and** a shared internal service key.

  Two independent gates, evaluated in order:

    1. **Feature flag.** Unless `Application.get_env(:offer_service,
       :force_expire_seam_enabled, false)` is `true`, the route responds `404
       not_found` and halts — the seam is *invisible* to real traffic and to
       probes. Default-off: production must opt in explicitly via
       `FORCE_EXPIRE_SEAM_ENABLED=true` (see `config/runtime.exs`).

    2. **Service key.** The caller must present `X-Service-Auth-Key` matching the
       configured internal `:service_token`. Comparison is constant-time
       (`Plug.Crypto.secure_compare/2`). A missing/blank configured token (no
       secret provisioned) fails closed: every request is rejected `401`. A
       missing/wrong header is `401 unauthorized`.

  This plug intentionally records NO user identity and performs NO ownership
  check — it authorizes a *trusted internal caller*, not an end user. It is
  never placed on user-facing routes.
  """

  import Plug.Conn

  alias OfferServiceWeb.ErrorJSON

  @header "x-service-auth-key"

  def init(opts), do: opts

  def call(conn, _opts) do
    if seam_enabled?() do
      authorize_service(conn)
    else
      # Flag off: behave as if the route does not exist.
      halt_json(conn, 404, "404.json")
    end
  end

  defp authorize_service(conn) do
    configured = configured_token()
    presented = presented_token(conn)

    cond do
      not is_binary(configured) or configured == "" ->
        # No internal token provisioned — fail closed.
        halt_json(conn, 401, "401.json")

      is_binary(presented) and Plug.Crypto.secure_compare(presented, configured) ->
        conn

      true ->
        halt_json(conn, 401, "401.json")
    end
  end

  defp seam_enabled? do
    Application.get_env(:offer_service, :force_expire_seam_enabled, false) == true
  end

  defp configured_token do
    Application.get_env(:offer_service, :service_token)
  end

  defp presented_token(conn) do
    case get_req_header(conn, @header) do
      [value | _] when is_binary(value) and byte_size(value) > 0 -> value
      _ -> nil
    end
  end

  defp halt_json(conn, status, template) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(ErrorJSON.render(template, %{})))
    |> halt()
  end
end
