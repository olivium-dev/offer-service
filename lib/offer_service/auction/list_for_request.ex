defmodule OfferService.Auction.ListForRequest do
  @moduledoc """
  Implements `GET /api/v1/requests/:request_id/offers` — the client-facing
  read of all offers on a request (the accept-sheet / bid-review list).

  ## Why this exists

  The auction had four write/auction routes (submit / edit / withdraw / accept)
  and the offer-scoped reject, but NO read route. The consuming gateway's
  accept-sheet (`GET /v1/requests/{id}/offers`, `GET /v1/offers?requestId=`)
  therefore had no upstream to call and surfaced a 500 (the BFF store threw
  `NotSupportedException`). This module is the missing query command.

  ## Route shape and authorization

  Mirrors the `Reject` / `AcceptByOffer` ownership model: only the CLIENT who
  owns the parent request may read its offer list (`request.client_id ==
  actor_id`). The bidding actors do not list a request's offers through this
  route — they see their own offer via the write responses. A non-owner gets
  `403 :forbidden`; an unknown request gets `404 :not_found`.

  Read-only — no transaction, no lock, no audit row, no telemetry. The request
  lifecycle state (open / accepted / expired / cancelled) does NOT gate the
  read: a client polls this during the auction window and may also re-read it
  after acceptance, so every status returns its offers (an empty list when the
  request exists but has no offers yet — never a 404).

  Offers are returned newest-first (`inserted_at` desc).
  """

  import Ecto.Query

  alias OfferService.Auction.{Offer, Request}
  alias OfferService.Repo

  # actor_id is the opaque external client identity (gateway JWT `sub`), not a uuid.
  @type actor_id :: binary()
  @type error_reason :: :not_found | :forbidden

  @doc """
  List every offer on `request_id` for the request's owning CLIENT.

  Resolves the parent request, enforces `request.client_id == actor_id`, then
  returns the offers newest-first. Returns `{:ok, [%Offer{}]}` (possibly empty)
  or a tagged `{:error, :not_found | :forbidden}` mapped to HTTP by
  `OfferServiceWeb.FallbackController`.
  """
  @spec run(actor_id(), Ecto.UUID.t()) :: {:ok, [Offer.t()]} | {:error, error_reason()}
  def run(actor_id, request_id) when is_binary(actor_id) and is_binary(request_id) do
    case Repo.one(from r in Request, where: r.id == ^request_id) do
      nil ->
        {:error, :not_found}

      %Request{client_id: ^actor_id} ->
        offers =
          Repo.all(
            from o in Offer,
              where: o.request_id == ^request_id,
              order_by: [desc: o.inserted_at, desc: o.id]
          )

        {:ok, offers}

      %Request{} ->
        {:error, :forbidden}
    end
  end
end
