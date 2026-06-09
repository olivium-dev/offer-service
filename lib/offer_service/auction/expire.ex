defmodule OfferService.Auction.Expire do
  @moduledoc """
  Force-expire a single offer — the **guarded test-seam** behind
  `POST /api/v1/offers/:offer_id/force-expire` (S07 / N3, additive).

  ## Why this exists

  offer-service expiry is, by design, time/clock-driven: an offer's parent
  auction lapses after its TTL and the offer becomes terminal (`expired`). There
  is no synchronous, deterministic API to drive a *specific* offer to `expired`
  for an end-to-end assertion — the E2E suite needs exactly that to prove
  BR-OFR-8: *accepting an EXPIRED offer returns 410*.

  This module is the deterministic counterpart of the natural TTL sweep. It
  transitions one offer `submitted | edited | pending → expired` in a single
  transaction, writing the same `offer_events` audit row and emitting the same
  `[:offer, :transition]` telemetry as every other lifecycle action — so the
  expired offer is indistinguishable from one that lapsed naturally. After it
  runs, the existing accept saga's `load_target_offer/2` short-circuits on the
  `expired` status and returns `:offer_expired`, which
  `OfferServiceWeb.FallbackController` maps to **HTTP 410**.

  ## Guarding (defence in depth — the web layer owns auth)

  This is a privileged maintenance/test operation, NOT a user action. It is
  reachable only when BOTH hold (enforced by the router pipeline, never here):

    1. The caller presents a valid `X-Service-Auth-Key` matching the internal
       `:service_token` (`OfferServiceWeb.Plugs.ServiceAuth`).
    2. The `:force_expire_seam_enabled` feature flag is `true`
       (default `false`; see `config/runtime.exs`). When the flag is off the
       route 404s so the seam is invisible to real traffic.

  The domain function itself performs no ownership check — it trusts that the
  pipeline above has authorized the (internal) caller. It deliberately does NOT
  expose a `request.client_id`/`offer.actor_id` gate, because the seam must be
  drivable by an out-of-band operator/test harness that is neither party.

  ## Idempotency

  Re-expiring an already-expired offer returns `{:error, :offer_expired}`
  (HTTP 410), mirroring `Withdraw`'s re-withdraw semantics — the terminal state
  is reported, not re-applied.

  Guards (in order):

    1. Offer exists (`:not_found`).
    2. `StateMachine.apply/2` permits `:expire` from the current state, else the
       structured terminal error (`:offer_expired`, `:offer_withdrawn`,
       `:already_accepted`, `:already_rejected`, `:invalid_transition`).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, StateMachine}
  alias OfferService.Repo

  @type error_reason ::
          :not_found
          | :offer_expired
          | :offer_withdrawn
          | :already_accepted
          | :already_rejected
          | :invalid_transition
          | :concurrent_modification

  @doc """
  Force a single offer to the terminal `expired` state.

  `actor_id` is the opaque identity recorded on the audit row for the operator
  that triggered the seam (the gateway-forwarded `x-user-id`, or the literal
  `"system"` when the seam is driven service-to-service with no user context).
  """
  @spec run(actor_id :: binary(), offer_id :: Ecto.UUID.t()) ::
          {:ok, Offer.t()} | {:error, error_reason()}
  def run(actor_id, offer_id) when is_binary(actor_id) and is_binary(offer_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:offer, fn repo, _ -> lock_offer(repo, offer_id) end)
    |> Multi.run(:transition, fn _repo, %{offer: offer} -> validate_transition(offer) end)
    |> Multi.update(:expired_offer, fn %{offer: offer} -> Offer.expire_changeset(offer) end)
    |> Multi.insert(:audit, fn %{offer: prev, expired_offer: next} ->
      OfferEvent.new_changeset(%{
        offer_id: next.id,
        request_id: next.request_id,
        actor_id: actor_id,
        action: "expire",
        from_state: prev.status,
        to_state: next.status,
        payload: %{"expired_at" => DateTime.to_iso8601(now), "seam" => "force_expire"},
        inserted_at: now
      })
    end)
    |> Repo.transaction()
    |> handle_result(actor_id)
  rescue
    Ecto.StaleEntryError -> {:error, :concurrent_modification}
  end

  # --- Multi steps ---------------------------------------------------------

  defp lock_offer(repo, offer_id) do
    query =
      from o in Offer,
        where: o.id == ^offer_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, :not_found}
      %Offer{} = offer -> {:ok, offer}
    end
  end

  defp validate_transition(%Offer{status: status, edits_count: ec}) do
    record = %{state: StateMachine.normalize_state(status), edits_count: ec}

    case StateMachine.apply(record, :expire) do
      {:ok, next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- result mapping ------------------------------------------------------

  defp handle_result({:ok, %{offer: prev, expired_offer: next}}, actor_id) do
    AuditLog.emit_telemetry(%{
      offer_id: next.id,
      request_id: next.request_id,
      actor_id: actor_id,
      action: :expire,
      from_state: prev.status,
      to_state: next.status
    })

    {:ok, next}
  end

  defp handle_result({:error, _step, reason, _changes}, _actor_id) when is_atom(reason),
    do: {:error, reason}

  defp handle_result({:error, _step, %Ecto.Changeset{}, _changes}, _actor_id),
    do: {:error, :concurrent_modification}

  defp handle_result({:error, _step, _other, _changes}, _actor_id),
    do: {:error, :concurrent_modification}
end
