defmodule OfferServiceWeb.Plugs.AuthenticatedUser do
  @moduledoc """
  Trusts the gateway-injected `x-user-id` header (the gateway terminates the
  user-facing JWT and forwards user claims as headers to internal services).
  All internal routes must be reachable only from inside the trusted network.
  """

  import Plug.Conn

  alias OfferServiceWeb.ErrorJSON

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "x-user-id") do
      [user_id] when byte_size(user_id) > 0 ->
        assign(conn, :current_user_id, user_id)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(ErrorJSON.render("401.json", %{})))
        |> halt()
    end
  end
end
