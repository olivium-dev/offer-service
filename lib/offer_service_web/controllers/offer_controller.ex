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

  Generic atomic auction close:

    * marks the chosen offer `accepted`, all siblings `rejected`;
    * transitions the parent request to `accepted`.

  Returns ONLY the generic transition outcome (accepted offer id + rejected
  sibling ids). Product-domain side effects (OTP, conversation/chat-thread,
  notification fan-out) are owned by the consuming gateway (JEB-1474).

  The `Idempotency-Key` header (case-insensitive) is **mandatory**.
  Replays with the same key and same payload return the cached
  response verbatim; replays with the same key and a divergent
  payload return `422 idempotency_mismatch`.
  """
  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, %{"request_id" => request_id, "offer_id" => offer_id} = params) do
    opts = [confirm_high_fee: truthy?(params["confirm_high_fee"])]

    with {:ok, idem_key} <- fetch_idempotency_key(conn),
         {:ok, request_uuid} <- cast_uuid(request_id),
         {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, mode, body} <-
           Auction.accept_offer_idempotent(
             idem_key,
             conn.assigns.current_user_id,
             request_uuid,
             offer_uuid,
             opts,
             &serialize_accept/1
           ) do
      conn
      |> put_resp_header("x-idempotency-replay", to_string(mode == :replay))
      |> put_status(:ok)
      |> json(body)
    end
  end

  @doc """
  POST /api/v1/offers/:offer_id/accept (S07 / OS-4, additive).

  Offer-scoped accept for the gateway's `POST /offers/{offer_id}/accept` route.
  The parent request is resolved from the offer; authorization is request-owner
  ownership (the owner of the request accepts a bid; any other caller —
  including the offer's own submitter — gets 403). Delegates to the same
  idempotent saga as `accept/2`, so every negative (404/403/410/409/422) and the
  success envelope are produced by the existing domain code — this action only
  resolves the offer and forwards the `Idempotency-Key`.
  """
  @spec accept_by_offer(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept_by_offer(conn, %{"offer_id" => offer_id} = params) do
    opts = [confirm_high_fee: truthy?(params["confirm_high_fee"])]

    with {:ok, idem_key} <- fetch_idempotency_key(conn),
         {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, mode, body} <-
           Auction.accept_offer_by_id(
             idem_key,
             conn.assigns.current_user_id,
             offer_uuid,
             opts,
             &serialize_accept/1
           ) do
      conn
      |> put_resp_header("x-idempotency-replay", to_string(mode == :replay))
      |> put_status(:ok)
      |> json(body)
    end
  end

  @doc """
  POST /api/v1/offers/:offer_id/reject (S08 / A5, additive).

  Offer-scoped owner rejection of a single bid — the route the gateway forwards
  `POST /offers/{offer_id}/reject` to. The parent request is resolved from the
  offer; authorization is request-owner ownership (the owner of the request
  rejects one bid; any other caller — including the offer's own submitter —
  gets 403). The auction is NOT closed: the request stays `open` so the owner
  may still accept another offer. Distinct from `withdraw/2` (the bidding actor
  retracting its own bid).

  200 on success with the serialized offer (`status: "rejected"`). Maps:

    * 404 — offer (or its parent request) does not exist
    * 403 — caller is not the request's Client
    * 410 — offer is terminal (`offer_withdrawn` / `offer_expired`)
    * 409 — offer already accepted/rejected, or concurrent modification
  """
  @spec reject(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reject(conn, %{"offer_id" => offer_id}) do
    with {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, offer} <- Auction.reject_offer(conn.assigns.current_user_id, offer_uuid) do
      conn
      |> put_status(:ok)
      |> json(serialize(offer))
    end
  end

  @doc """
  POST /api/v1/offers/:offer_id/force-expire (S07 / N3 test-seam, additive).

  Drives a single offer to the terminal `expired` state so the E2E suite can
  assert BR-OFR-8 (accepting an EXPIRED offer returns 410) deterministically,
  without waiting on the natural TTL sweep. After a 200 here, an accept on the
  same offer returns 410 `offer_expired`.

  This route is **guarded twice** by `OfferServiceWeb.Plugs.ServiceAuth`
  (mounted on a dedicated pipeline): it is reachable only when the
  `:force_expire_seam_enabled` flag is on (default off → 404) AND the caller
  presents a valid `X-Service-Auth-Key` (else 401). It is NOT a user-facing
  action and is never wired through the `AuthenticatedUser` plug.

  Maps:
    * 200 — offer driven to `expired`
    * 404 — offer does not exist (or seam flag off)
    * 410 — offer is already terminal (`offer_expired` / `offer_withdrawn`)
    * 409 — offer already accepted/rejected, or concurrent modification
  """
  @spec force_expire(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def force_expire(conn, %{"offer_id" => offer_id}) do
    with {:ok, offer_uuid} <- cast_uuid(offer_id),
         {:ok, offer} <- Auction.force_expire_offer(seam_actor_id(conn), offer_uuid) do
      conn
      |> put_status(:ok)
      |> json(serialize(offer))
    end
  end

  # The seam is service-authenticated, not user-authenticated, so there is no
  # `conn.assigns.current_user_id`. Record whichever opaque operator identity the
  # caller forwarded for the audit trail, falling back to "system".
  defp seam_actor_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-user-id") do
      [id | _] when is_binary(id) and byte_size(id) > 0 -> id
      _ -> "system"
    end
  end

  # AC2: accept either `Idempotency-Key` or `idempotency-key` (HTTP is
  # case-insensitive; Plug normalises but we don't trust upstream).
  defp fetch_idempotency_key(conn) do
    header =
      Plug.Conn.get_req_header(conn, "idempotency-key")
      |> Enum.find(&(is_binary(&1) and byte_size(String.trim(&1)) >= 8))

    cond do
      is_binary(header) -> {:ok, String.trim(header)}
      true -> {:error, :idempotency_key_required}
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
      note: params["note"],
      # JEB-1474 / AC2 — the edit ceiling is supplied by the consumer (gateway),
      # not hardcoded in the shared service. Forwarded to the edit saga; absent
      # ⇒ the configurable :max_edits fallback applies.
      max_edits: cast_integer(params["max_edits"])
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
      # Generic, canonical identity. `jeeber_id` is retained alongside as a
      # DEPRECATED, read-compatible wire alias for existing consumers.
      actor_id: offer.actor_id,
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

  # JEB-1474 — the accept response is ONLY the generic transition outcome:
  # the accepted offer id and the rejected sibling ids. No OTP, no chat-thread,
  # no notification side effects (all owned by the consuming gateway).
  defp serialize_accept(%{
         request: request,
         accepted_offer: offer,
         rejected_offer_ids: rejected_ids
       }) do
    %{
      request: %{
        id: request.id,
        status: request.status,
        accepted_offer_id: request.accepted_offer_id
      },
      accepted_offer: %{
        id: offer.id,
        actor_id: offer.actor_id,
        jeeber_id: offer.jeeber_id,
        fee_cents: offer.fee_cents,
        eta_minutes: offer.eta_minutes,
        status: offer.status,
        accepted_at: offer.accepted_at
      },
      rejected_offer_ids: rejected_ids
    }
  end
end
