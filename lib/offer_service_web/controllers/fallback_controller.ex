defmodule OfferServiceWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  alias OfferServiceWeb.ErrorJSON

  def call(conn, {:error, :not_found}), do: render_error(conn, 404)
  def call(conn, {:error, :forbidden}), do: render_error(conn, 403)
  def call(conn, {:error, :unauthorized}), do: render_error(conn, 401)

  def call(conn, {:error, :request_not_open}),
    do: render_error(conn, 409, "Auction is already closed for this request")

  def call(conn, {:error, :offer_not_pending}),
    do: render_error(conn, 409, "Offer is not in a pending state")

  def call(conn, {:error, :concurrent_modification}),
    do: render_error(conn, 409, "Another acceptance is in flight, please retry")

  def call(conn, {:error, :high_fee_confirmation_required}),
    do:
      render_error(
        conn,
        409,
        "Offer fee exceeds the high-fee threshold; resend with confirm_high_fee=true"
      )

  def call(conn, {:error, :chat_service_unavailable}),
    do: render_error(conn, 502, "Chat service is temporarily unavailable")

  def call(conn, {:error, %Ecto.Changeset{} = cs}) do
    conn
    |> Plug.Conn.put_status(422)
    |> Phoenix.Controller.put_view(json: ErrorJSON)
    |> Phoenix.Controller.render("422.json", message: changeset_message(cs))
  end

  def call(conn, _other), do: render_error(conn, 500)

  defp render_error(conn, status, message \\ nil) do
    template = "#{status}.json"

    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.put_view(json: ErrorJSON)
    |> Phoenix.Controller.render(template, message: message)
  end

  defp changeset_message(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
  end
end
