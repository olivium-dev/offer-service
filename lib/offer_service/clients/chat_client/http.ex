defmodule OfferService.Clients.ChatClient.HTTP do
  @moduledoc "Production HTTP implementation of `OfferService.Clients.ChatClient`."

  @behaviour OfferService.Clients.ChatClient

  require Logger

  @impl true
  def create_thread(%{
        request_id: request_id,
        offer_id: offer_id,
        client_id: client_id,
        jeeber_id: jeeber_id
      }) do
    url = Application.fetch_env!(:offer_service, :chat_service_url) <> "/internal/threads"

    # The provider participant carries the generic `role: "provider"` token.
    # `legacy_role: "jeeber"` is an additive backward-compat alias so any
    # consumer still keying on the legacy "jeeber" string keeps working
    # (chat-service treats `role` as an opaque free-form string, so this is
    # non-breaking). Emit BOTH tokens.
    body = %{
      request_id: request_id,
      offer_id: offer_id,
      participants: [
        %{user_id: client_id, role: "client"},
        %{user_id: jeeber_id, role: "provider", legacy_role: "jeeber"}
      ]
    }

    case Req.post(url, json: body, headers: auth_headers(), receive_timeout: 5_000) do
      {:ok, %{status: status, body: %{"thread_id" => thread_id}}}
      when status in 200..299 ->
        {:ok, %{thread_id: thread_id}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("chat_service.create_thread non_2xx",
          status: status,
          body: inspect(body)
        )

        {:error, :chat_service_unavailable}

      {:error, reason} ->
        Logger.error("chat_service.create_thread failed", reason: inspect(reason))
        {:error, :chat_service_unavailable}
    end
  end

  defp auth_headers do
    case Application.get_env(:offer_service, :service_token) do
      nil -> []
      token -> [{"authorization", "Bearer " <> token}]
    end
  end
end
