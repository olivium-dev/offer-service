defmodule OfferServiceWeb.OfferController do
  use OfferServiceWeb, :controller

  alias OfferService.Auction

  @doc """
  POST /api/v1/requests/:request_id/offers/:offer_id/accept

  Body (optional):
    `{ "confirm_high_fee": true }` — required when the offer fee is above the
    high-fee threshold (default: 5000 cents / $50).

  Success response (200): includes the 4-digit OTP. Only the Client (the
  acceptor) ever sees this; the persisted record stores only its hash.
  """
  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, %{"request_id" => request_id, "offer_id" => offer_id} = params) do
    opts = [confirm_high_fee: truthy?(params["confirm_high_fee"])]

    with {:ok, request_uuid} <- Ecto.UUID.cast(request_id),
         {:ok, offer_uuid} <- Ecto.UUID.cast(offer_id),
         {:ok, result} <-
           Auction.accept_offer(conn.assigns.current_user_id, request_uuid, offer_uuid, opts) do
      conn
      |> put_status(:ok)
      |> json(serialize(result))
    else
      :error -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp serialize(%{
         request: request,
         accepted_offer: offer,
         rejected_offer_ids: rejected_ids,
         otp_code: otp_code,
         thread_id: thread_id
       }) do
    %{
      request: %{
        id: request.id,
        status: request.status,
        accepted_offer_id: request.accepted_offer_id,
        chat_thread_id: request.chat_thread_id
      },
      accepted_offer: %{
        id: offer.id,
        jeeber_id: offer.jeeber_id,
        fee_cents: offer.fee_cents,
        eta_minutes: offer.eta_minutes,
        status: offer.status,
        accepted_at: offer.accepted_at
      },
      rejected_offer_ids: rejected_ids,
      chat_thread_id: thread_id,
      otp_code: otp_code
    }
  end
end
