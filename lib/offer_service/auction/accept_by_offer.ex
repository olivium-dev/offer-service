defmodule OfferService.Auction.AcceptByOffer do
  @moduledoc """
  Offer-scoped acceptance entrypoint: `POST /api/v1/offers/:offer_id/accept`
  (S07 / OS-4, additive).

  ## Why this exists

  The Jeeb mobile/gateway accept route is **offer-scoped**
  (`POST /offers/{offer_id}/accept`) — the caller holds an `offer_id`, not the
  parent `request_id`. The canonical request-scoped saga
  (`POST /api/v1/requests/:request_id/offers/:offer_id/accept`) requires both
  ids and authorizes on REQUEST ownership (`request.client_id == actor_id`).

  This module bridges the two **without inter-service coupling and without any
  gateway-side state**: it resolves the offer's `request_id` from the offer row
  itself, then delegates to the existing idempotent accept saga. The gateway can
  therefore forward just the `offer_id` + the acting Jeeber id + the
  `Idempotency-Key` and stay a stateless thin BFF.

  ## Authorization model (the difference from the request-scoped route)

  The offer-scoped accept is **OFFER-owner gated**: the Jeeber the offer was
  extended to is the one who accepts it. Any other caller (a different Jeeber,
  or the request's client) gets `403 :forbidden` — the auction-close saga is
  never entered. This matches the Jeeb product rule the gateway already enforced
  in-memory (`OffersController.Accept` offer-not-owned guard). Because ownership
  is established HERE, the saga is invoked with `authorize: false` so its
  request-client guard does not double-reject the legitimate Jeeber.

  All downstream negatives (`410` request_expired / offer_withdrawn,
  `409` already_accepted / not-pending / concurrent_modification, `404`
  not_found) and the success envelope are produced verbatim by the existing
  saga + `Idempotency` layer — this module adds no new domain logic, only the
  offer→request resolution and the offer-ownership gate.
  """

  alias OfferService.Auction.{Idempotency, Offer}
  alias OfferService.Repo

  # Opaque external identity (gateway JWT `sub`), not necessarily a uuid.
  @type actor_id :: binary()
  @type offer_id :: Ecto.UUID.t()
  @type idem_key :: binary()

  @type result ::
          {:ok, :fresh | :replay, map()}
          | {:error,
             :not_found
             | :forbidden
             | :idempotency_mismatch
             | OfferService.Auction.Acceptance.error_reason()}

  @doc """
  Accept an offer by its id, idempotently.

  Resolves the parent request from the offer, enforces offer-ownership, then
  runs the existing idempotent accept saga keyed on `(request_id, offer_id)`.
  Returns the same `{:ok, mode, wire}` / `{:error, reason}` shape as
  `OfferService.Auction.accept_offer_idempotent/6`.
  """
  @spec run(idem_key(), actor_id(), offer_id(), keyword(), (map() -> map())) :: result()
  def run(idempotency_key, actor_id, offer_id, opts \\ [], serializer \\ & &1)
      when is_binary(idempotency_key) and is_binary(actor_id) and is_binary(offer_id) do
    case Repo.get(Offer, offer_id) do
      nil ->
        {:error, :not_found}

      %Offer{jeeber_id: owner_id} when owner_id != actor_id ->
        # Offer was extended to a different Jeeber — 403, never enter the saga.
        {:error, :forbidden}

      %Offer{request_id: request_id} ->
        Idempotency.run(
          idempotency_key,
          actor_id,
          request_id,
          offer_id,
          Keyword.put(opts, :authorize, false),
          serializer
        )
    end
  end
end
