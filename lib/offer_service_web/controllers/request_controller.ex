defmodule OfferServiceWeb.RequestController do
  use OfferServiceWeb, :controller

  alias OfferService.Auction
  alias OfferService.Auction.Request

  # `action_fallback OfferServiceWeb.FallbackController` is injected by the
  # `OfferServiceWeb, :controller` macro.

  @doc """
  POST /api/v1/requests — gateway request-bridge.

  Idempotently mirrors a gateway-created request into offer-service so that
  subsequent offer submits against `request_id` resolve. The gateway is the
  system-of-record and forwards the id it already issued.

  Body: `{ "request_id": "<uuid>", "client_id": "<uuid>", "status": "open" }`
  (`id` is accepted as an alias for `request_id`; `status` defaults to `open`).

  Responses:

    * 201 — request mirrored for the first time
    * 200 — request already mirrored (idempotent replay; current lifecycle
      state preserved, never reset)
    * 422 — payload fails validation (missing/invalid `client_id`)
    * 400 — `request_id`/`id` is missing or not a UUID

  The acting `client_id` is taken from the body rather than the gateway-injected
  `x-user-id` header so the gateway can mirror on the request-creator's behalf.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case Auction.upsert_request(params) do
      {:ok, :created, request} ->
        conn
        |> put_status(:created)
        |> json(serialize(request))

      {:ok, :exists, request} ->
        conn
        |> put_resp_header("x-idempotency-replay", "true")
        |> put_status(:ok)
        |> json(serialize(request))

      {:error, :invalid_id} ->
        {:error, :request_id_required}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  defp serialize(%Request{} = request) do
    %{
      id: request.id,
      request_id: request.id,
      client_id: request.client_id,
      status: request.status,
      accepted_offer_id: request.accepted_offer_id,
      chat_thread_id: request.chat_thread_id,
      created_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end
end
