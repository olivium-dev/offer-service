defmodule OfferService.Clients.NotificationClient.HTTP do
  @moduledoc "Production HTTP implementation of `OfferService.Clients.NotificationClient`."

  @behaviour OfferService.Clients.NotificationClient

  require Logger

  @impl true
  def notify(%{user_id: user_id, event: event, payload: payload}) do
    url = Application.fetch_env!(:offer_service, :notification_service_url) <> "/internal/notify"

    body = %{
      recipient_id: user_id,
      event: Atom.to_string(event),
      payload: payload
    }

    case Req.post(url, json: body, headers: auth_headers(), receive_timeout: 3_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("notification_service.notify non_2xx",
          status: status,
          body: inspect(body)
        )

        {:error, :notification_service_unavailable}

      {:error, reason} ->
        Logger.error("notification_service.notify failed", reason: inspect(reason))
        {:error, :notification_service_unavailable}
    end
  end

  defp auth_headers do
    case Application.get_env(:offer_service, :service_token) do
      nil -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end
end
