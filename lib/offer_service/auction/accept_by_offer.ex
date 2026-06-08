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

  ## Authorization model (identical to the request-scoped route)

  The auction acceptor in S07 is the **CLIENT who owns the parent request** —
  the Jeeber *submits* an offer (a bid); the Client *accepts* one of those
  offers, which closes the auction and creates the delivery. So the authorized
  acceptor on BOTH the request-scoped and the offer-scoped routes is
  `request.client_id == actor_id`. A Jeeber (even the offer's own Jeeber) is NOT
  the acceptor and gets `403 :forbidden`.

  This module resolves the offer's parent `request_id` from the offer row, then
  delegates to the existing idempotent accept saga **with authorization left
  ON** (`authorize: true`, the default). The saga's request-client guard
  (`OfferService.Auction.Acceptance.lock_request/4`, the
  `client_id != actor_id -> {:error, :forbidden}` clause) is the single source
  of truth for the ownership decision — this module does not re-implement it,
  avoiding the previous inverted (jeeber-owner) gate.

  All downstream negatives (`410` request_expired / offer_withdrawn,
  `409` already_accepted / not-pending / concurrent_modification, `403`
  non-owner, `404` not_found) and the success envelope are produced verbatim by
  the existing saga + `Idempotency` layer — this module adds no new domain
  logic, only the offer→request resolution.
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

  Resolves the parent request from the offer, then runs the existing idempotent
  accept saga keyed on `(request_id, offer_id)` with authorization left ON, so
  the saga's request-CLIENT ownership guard decides 403. Returns the same
  `{:ok, mode, wire}` / `{:error, reason}` shape as
  `OfferService.Auction.accept_offer_idempotent/6`.

  Authorization is the CLIENT who owns the parent request (`request.client_id ==
  actor_id`); a Jeeber — including the offer's own Jeeber — is rejected with
  `:forbidden` by the saga.
  """
  @spec run(idem_key(), actor_id(), offer_id(), keyword(), (map() -> map())) :: result()
  def run(idempotency_key, actor_id, offer_id, opts \\ [], serializer \\ & &1)
      when is_binary(idempotency_key) and is_binary(actor_id) and is_binary(offer_id) do
    case Repo.get(Offer, offer_id) do
      nil ->
        {:error, :not_found}

      %Offer{request_id: request_id} ->
        # Delegate to the idempotent saga with authorization ON (the default):
        # the saga authorizes on request-CLIENT ownership
        # (`request.client_id == actor_id`), which is the correct S07 rule —
        # the Client accepts a Jeeber's bid. We deliberately do NOT pass
        # `authorize: false`, so a Jeeber acceptor (or any non-owner) is
        # rejected with `:forbidden`. opts is forwarded verbatim
        # (e.g. `confirm_high_fee:`), keeping the idempotency fingerprint
        # stable across replays.
        Idempotency.run(
          idempotency_key,
          actor_id,
          request_id,
          offer_id,
          opts,
          serializer
        )
    end
  end
end
