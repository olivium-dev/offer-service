defmodule OfferService.Auction do
  @moduledoc """
  Public API for the offer auction bounded context.

  All callers — controllers, channels, other contexts — must enter the
  domain through this module. The internal modules (`Submit`, `Edit`,
  `Withdraw`, `Acceptance`, `StateMachine`, `AuditLog`) are considered
  private and may be reshuffled without notice.

  Every state-changing function:

    * Runs inside an `Ecto.Multi` transaction.
    * Writes an `offer_events` audit row.
    * Emits a `[:offer, :transition]` telemetry event on commit.

  Errors are returned as tagged atoms so the web layer can map them to
  HTTP statuses in `OfferServiceWeb.FallbackController` without leaking
  internals.
  """

  alias OfferService.Auction.{Acceptance, Edit, Idempotency, Submit, Withdraw}

  @doc "Submit a brand-new offer for `request_id` on behalf of `actor_id`."
  defdelegate submit_offer(actor_id, request_id, attrs), to: Submit, as: :run

  @doc "Edit an existing offer (≤2 times). 3rd edit returns `:edit_limit_reached`."
  defdelegate edit_offer(actor_id, request_id, offer_id, attrs), to: Edit, as: :run

  @doc "Withdraw an offer. Terminal — cannot be re-submitted under the same (request, jeeber)."
  defdelegate withdraw_offer(actor_id, request_id, offer_id), to: Withdraw, as: :run

  @doc "Accept an offer (called by the Client/gateway). First writer wins."
  defdelegate accept_offer(actor_id, request_id, offer_id, opts \\ []), to: Acceptance, as: :run

  @doc """
  Accept an offer **idempotently** (JEB-49 / AC2).

  The `idempotency_key` (typically the `Idempotency-Key` HTTP header)
  scopes the cached response by `(client_id, request_id, key)`. A
  replay with the same fingerprint returns the previously persisted
  response without re-running the saga. A replay with the same key
  but a divergent fingerprint returns `{:error, :idempotency_mismatch}`.
  """
  defdelegate accept_offer_idempotent(
                idempotency_key,
                actor_id,
                request_id,
                offer_id,
                opts \\ [],
                serializer \\ &(&1)
              ),
              to: Idempotency,
              as: :run
end
