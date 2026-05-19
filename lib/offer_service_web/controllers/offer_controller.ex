defmodule OfferServiceWeb.OfferController do
  use OfferServiceWeb, :controller

  alias OfferService.Auction
  alias OfferService.Auction.Offer

  @doc """
  POST /api/v1/requests/:request_id/offers

  Body: `{ "fee_cents": 1500, "eta_minutes": 25, "note": "free text" }`

  201 on success with the serialized offer. Maps:

    * 404 — request does not exist
    * 409 — request is no longer open ("request_not_open")
    * 409 — actor already submitted an offer for this request
    * 422 — payload fails validation
  """
  @spec submit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def submit(conn, %{"request_id" => request_id} = params) do
    with {:ok, request_uuid} <- cast_uuid(request_id),
         {:ok, offer} <-
           Auction.submit_offer(conn.assigns.current_user_id, request_uuid, attrs(params)) do
      conn
      |> put_status(:created)
      |> json(serialize(offer))
    end
  end

  @doc """
  PUT /api/v1/requests/:request_id/offers/:offer_id

  Re-prices / re-ETAs / re-notes an offer. Up to two times; the third call
  returns 422 `edit_limit_reached`.
  """
  @spec edit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def edit(conn, %{"request_id" => request_id, "offer_id" => offer_id} = params) do
    with {:ok, request_uuid} <- cast_uuid(request_id),
         {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, offer} <-
           Auction.edit_offer(
             conn.assigns.current_user_id,
             request_uuid,
             offer_uuid,
             attrs(params)
           ) do
      conn
      |> put_status(:ok)
      |> json(serialize(offer))
    end
  end

  @doc """
  DELETE /api/v1/requests/:request_id/offers/:offer_id

  Marks the offer as withdrawn. After this, accept calls on it return 410.
  """
  @spec withdraw(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def withdraw(conn, %{"request_id" => request_id, "offer_id" => offer_id}) do
    with {:ok, request_uuid} <- cast_uuid(request_id),
         {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, offer} <-
           Auction.withdraw_offer(conn.assigns.current_user_id, request_uuid, offer_uuid) do
      conn
      |> put_status(:ok)
      |> json(serialize(offer))
    end
  end

  @doc """
  POST /api/v1/requests/:request_id/offers/:offer_id/accept
  (Inherited from JEB-47; preserved.)
  """
  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, %{"request_id" => request_id, "offer_id" => offer_id} = params) do
    opts = [confirm_high_fee: truthy?(params["confirm_high_fee"])]

    with {:ok, request_uuid} <- cast_uuid(request_id),
         {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, result} <-
           Auction.accept_offer(conn.assigns.current_user_id, request_uuid, offer_uuid, opts) do
      conn
      |> put_status(:ok)
      |> json(serialize_accept(result))
    end
  end

  # --- helpers -------------------------------------------------------------

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp attrs(params) do
    %{
      fee_cents: cast_integer(params["fee_cents"]),
      eta_minutes: cast_integer(params["eta_minutes"]),
      note: params["note"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp cast_integer(nil), do: nil
  defp cast_integer(n) when is_integer(n), do: n

  defp cast_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> s
    end
  end

  defp cast_integer(other), do: other

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp serialize(%Offer{} = offer) do
    %{
      id: offer.id,
      request_id: offer.request_id,
      jeeber_id: offer.jeeber_id,
      fee_cents: offer.fee_cents,
      eta_minutes: offer.eta_minutes,
      note: offer.note,
      status: offer.status,
      edits_count: offer.edits_count,
      created_at: offer.inserted_at,
      updated_at: offer.updated_at,
      withdrawn_at: offer.withdrawn_at
    }
  end

  defp serialize_accept(%{
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
