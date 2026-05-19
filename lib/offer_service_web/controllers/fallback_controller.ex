defmodule OfferServiceWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  alias OfferServiceWeb.ErrorJSON

  def call(conn, {:error, :not_found}), do: render_error(conn, 404, "not_found")
  def call(conn, {:error, :forbidden}), do: render_error(conn, 403, "forbidden")
  def call(conn, {:error, :unauthorized}), do: render_error(conn, 401, "unauthorized")

  # Offer submit / edit / withdraw / accept

  def call(conn, {:error, :request_not_open}),
    do:
      render_error(
        conn,
        409,
        "conflict",
        "Request is no longer accepting offers (state != open)"
      )

  # JEB-49 / AC4 — terminal lifecycle states map to HTTP 410.
  def call(conn, {:error, :request_expired}),
    do:
      render_error(
        conn,
        410,
        "request_expired",
        "Delivery request expired and is no longer actionable"
      )

  def call(conn, {:error, :request_cancelled}),
    do:
      render_error(
        conn,
        410,
        "request_cancelled",
        "Delivery request was cancelled and is no longer actionable"
      )

  # JEB-49 / AC3 — race-loss with winner identity.
  def call(conn, {:error, {:already_accepted, winner_user_id}}) do
    body = %{
      "error" => %{
        "code" => "already_accepted",
        "message" => "Request was accepted by another participant",
        "winner_user_id" => winner_user_id
      }
    }

    conn
    |> Plug.Conn.put_status(409)
    |> Phoenix.Controller.json(body)
  end

  # JEB-49 / AC2 — idempotency contract violations.
  def call(conn, {:error, :idempotency_key_required}),
    do:
      render_error(
        conn,
        400,
        "idempotency_key_required",
        "Idempotency-Key header is required and must be at least 8 chars"
      )

  def call(conn, {:error, :idempotency_mismatch}),
    do:
      render_error(
        conn,
        422,
        "idempotency_mismatch",
        "The same Idempotency-Key was reused with a divergent payload"
      )

  def call(conn, {:error, :already_submitted}),
    do:
      render_error(
        conn,
        409,
        "conflict",
        "An offer for this request already exists for the current user"
      )

  def call(conn, {:error, :edit_limit_reached}),
    do:
      render_error(
        conn,
        422,
        "edit_limit_reached",
        "Offer has already been edited the maximum number of times (2)"
      )

  def call(conn, {:error, :offer_withdrawn}),
    do:
      render_error(
        conn,
        410,
        "offer_withdrawn",
        "Offer has been withdrawn and is no longer actionable"
      )

  def call(conn, {:error, :already_accepted}),
    do:
      render_error(
        conn,
        409,
        "already_accepted",
        "Offer has already been accepted and cannot be mutated"
      )

  def call(conn, {:error, :already_rejected}),
    do:
      render_error(
        conn,
        409,
        "already_rejected",
        "Offer has already been rejected and cannot be mutated"
      )

  def call(conn, {:error, :offer_expired}),
    do: render_error(conn, 410, "offer_expired", "Offer has expired and is no longer actionable")

  def call(conn, {:error, :offer_not_pending}),
    do: render_error(conn, 409, "conflict", "Offer is not in a pending state")

  def call(conn, {:error, :invalid_transition}),
    do:
      render_error(
        conn,
        409,
        "invalid_transition",
        "The requested action is not permitted from the offer's current state"
      )

  def call(conn, {:error, :concurrent_modification}),
    do:
      render_error(
        conn,
        409,
        "conflict",
        "Another mutation is in flight on this offer, please retry"
      )

  def call(conn, {:error, :high_fee_confirmation_required}),
    do:
      render_error(
        conn,
        409,
        "conflict",
        "Offer fee exceeds the high-fee threshold; resend with confirm_high_fee=true"
      )

  def call(conn, {:error, :chat_service_unavailable}),
    do: render_error(conn, 502, "bad_gateway", "Chat service is temporarily unavailable")

  def call(conn, {:error, %Ecto.Changeset{} = cs}) do
    conn
    |> Plug.Conn.put_status(422)
    |> Phoenix.Controller.put_view(json: ErrorJSON)
    |> Phoenix.Controller.render("422.json",
      code: "validation_failed",
      message: changeset_message(cs)
    )
  end

  def call(conn, _other), do: render_error(conn, 500, "internal_server_error")

  defp render_error(conn, status, code, message \\ nil) do
    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.put_view(json: ErrorJSON)
    |> Phoenix.Controller.render("#{status}.json", code: code, message: message)
  end

  defp changeset_message(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)
  end
end
