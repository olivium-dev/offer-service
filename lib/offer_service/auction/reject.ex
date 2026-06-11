defmodule OfferService.Auction.Reject do
  @moduledoc """
  Offer-scoped client rejection: `POST /api/v1/offers/:offer_id/reject`
  (S08 / A5, additive).

  ## Why this exists

  The auction has two distinct terminal-by-loser paths:

    * `Withdraw` — the bidding actor retracts its own bid
      (`actor_id == offer.actor_id`, route is request-scoped).
    * `Reject` (this module) — the client who owns the parent request declines a
      single bid *without* closing the auction. The client may keep shopping the
      remaining offers; only `Acceptance` closes the request and reject-fans the
      siblings.

  Prior to this module, `rejected` was produced **only** as a side effect of the
  accept saga (`Acceptance.reject_siblings/3`). There was no way for a client to
  reject one bid directly. The `StateMachine` already encodes the `:reject`
  action (`submitted | edited -> rejected`) and `Offer.reject_changeset/2`
  already exists; this module is the missing command that drives them.

  ## Route shape and authorization

  The gateway forwards `POST /offers/{offer_id}/reject` — it carries no
  `request_id`. So, mirroring `AcceptByOffer`, this module resolves the parent
  `request_id` from the offer row, then authorizes on **request-owner
  ownership** (`request.client_id == actor_id`). The bidding actor — including
  the offer's own submitter — is NOT the rejecter and gets `403 :forbidden`.

  Guards (in order, all inside one transaction):

    1. Offer exists (`:not_found`).
    2. Parent request exists and is row-locked `FOR UPDATE` (`:not_found`).
    3. `actor_id == request.client_id` (`:forbidden`).
    4. `StateMachine.apply/2` permits `:reject` from the offer's current state —
       terminal states map to `:offer_withdrawn` / `:already_accepted` /
       `:already_rejected` / `:offer_expired`, idempotent re-reject returns
       `:already_rejected` (HTTP 409).

  Side-effects inside the transaction:

    * Update offer (`status: "rejected"`, `rejected_at: now`) via
      `Offer.reject_changeset/2` (optimistic-locked on `lock_version`).
    * Insert an `offer_events` row (`action: "reject"`).

  Post-commit (NON-fatal, off the request path):

    * Emit `[:offer, :transition]` telemetry.

  Notification fan-out is NOT performed here — it is owned by the consuming
  gateway (JEB-1474 boundary remediation). This shared service emits only the
  generic transition + audit + telemetry.

  The request lifecycle is intentionally **untouched**: rejecting a bid leaves
  the request `open` so the client can still accept another offer. Only
  `Acceptance` writes the request to `accepted`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, Request, StateMachine}
  alias OfferService.Repo

  # actor_id is the opaque external client identity (gateway JWT `sub`), not a uuid.
  @type actor_id :: binary()
  @type offer_id :: Ecto.UUID.t()

  @type error_reason ::
          :not_found
          | :forbidden
          | :offer_withdrawn
          | :already_accepted
          | :already_rejected
          | :offer_expired
          | :invalid_transition
          | :concurrent_modification
          | Ecto.Changeset.t()

  @doc """
  Reject an offer by its id on behalf of the request CLIENT.

  Resolves the parent request from the offer, locks it, enforces
  `request.client_id == actor_id`, then drives the offer to `rejected`. Returns
  `{:ok, %Offer{status: "rejected"}}` or a tagged `{:error, reason}` mapped to
  HTTP by `OfferServiceWeb.FallbackController`.
  """
  @spec run(actor_id(), offer_id()) :: {:ok, Offer.t()} | {:error, error_reason()}
  def run(actor_id, offer_id) when is_binary(actor_id) and is_binary(offer_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:offer, fn repo, _ -> load_offer(repo, offer_id) end)
    |> Multi.run(:request, fn repo, %{offer: offer} ->
      lock_request(repo, offer.request_id, actor_id)
    end)
    |> Multi.run(:transition, fn _repo, %{offer: offer} -> validate_transition(offer) end)
    |> Multi.update(:rejected_offer, fn %{offer: offer} -> Offer.reject_changeset(offer, now) end)
    |> Multi.insert(:audit, fn %{offer: prev, rejected_offer: next} ->
      OfferEvent.new_changeset(%{
        offer_id: next.id,
        request_id: next.request_id,
        # The request owner is the acting actor on the audit trail (Withdraw
        # records the offer's submitter; Reject records the request owner). Both
        # are opaque text identities.
        actor_id: actor_id,
        action: "reject",
        from_state: prev.status,
        to_state: next.status,
        payload: %{
          "rejected_at" => DateTime.to_iso8601(now),
          "actor_id" => next.actor_id
        },
        inserted_at: now
      })
    end)
    |> Repo.transaction()
    |> handle_result(actor_id)
  rescue
    Ecto.StaleEntryError -> {:error, :concurrent_modification}
  end

  # --- Multi steps ---------------------------------------------------------

  defp load_offer(repo, offer_id) do
    case repo.one(from o in Offer, where: o.id == ^offer_id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      %Offer{} = offer -> {:ok, offer}
    end
  end

  # Lock + owner guard. A phantom request id is treated as `:not_found` (the
  # offer row would carry a dangling FK only under data corruption). Only the
  # request owner may reject; everyone else (including the offer's own
  # submitting actor) gets `:forbidden`.
  defp lock_request(repo, request_id, actor_id) do
    case repo.one(from r in Request, where: r.id == ^request_id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      %Request{client_id: ^actor_id} = request -> {:ok, request}
      %Request{} -> {:error, :forbidden}
    end
  end

  defp validate_transition(%Offer{status: status, edits_count: ec}) do
    record = %{state: StateMachine.normalize_state(status), edits_count: ec}

    case StateMachine.apply(record, :reject) do
      {:ok, next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- result mapping ------------------------------------------------------

  defp handle_result({:ok, %{offer: prev, rejected_offer: next}}, actor_id) do
    AuditLog.emit_telemetry(%{
      offer_id: next.id,
      request_id: next.request_id,
      actor_id: actor_id,
      action: :reject,
      from_state: prev.status,
      to_state: next.status,
      payload: %{}
    })

    {:ok, next}
  end

  defp handle_result({:error, _step, reason, _}, _actor_id) when is_atom(reason),
    do: {:error, reason}

  defp handle_result({:error, _step, %Ecto.Changeset{} = cs, _}, _actor_id), do: {:error, cs}
end
