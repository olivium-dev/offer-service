defmodule OfferService.Auction.Reject do
  @moduledoc """
  Offer-scoped client rejection: `POST /api/v1/offers/:offer_id/reject`
  (S08 / A5, additive).

  ## Why this exists

  The auction has two distinct terminal-by-loser paths:

    * `Withdraw` — the **Jeeber** retracts its own bid
      (`actor_id == offer.jeeber_id`, route is request-scoped).
    * `Reject` (this module) — the **Client** who owns the parent request
      declines a single Jeeber's bid *without* closing the auction. The Client
      may keep shopping the remaining offers; only `Acceptance` closes the
      request and reject-fans the siblings.

  Prior to this module, `rejected` was produced **only** as a side effect of the
  accept saga (`Acceptance.reject_siblings/3`). There was no way for a Client to
  reject one bid directly. The `StateMachine` already encodes the `:reject`
  action (`submitted | edited -> rejected`) and `Offer.reject_changeset/2`
  already exists; this module is the missing command that drives them.

  ## Route shape and authorization

  The Jeeb gateway forwards `POST /offers/{offer_id}/reject` — it carries no
  `request_id`. So, mirroring `AcceptByOffer`, this module resolves the parent
  `request_id` from the offer row, then authorizes on **request-CLIENT
  ownership** (`request.client_id == actor_id`). A Jeeber — including the
  offer's own Jeeber — is NOT the rejecter and gets `403 :forbidden`. This
  matches the realtime layer's `only_client_may_reject_offers` invariant.

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
    * Fan a single `:offer_rejected` push to the losing Jeeber, honoring the
      `:fanout_strategy` config (`:async` by default, `:sync` in tests). A
      notification failure never fails the rejection — the DB row is already
      committed.

  The request lifecycle is intentionally **untouched**: rejecting a bid leaves
  the request `open` so the Client can still accept another offer. Only
  `Acceptance` writes the request to `accepted`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, Request, StateMachine}
  alias OfferService.Clients.NotificationClient
  alias OfferService.Repo

  # actor_id is the opaque external CLIENT identity (gateway JWT `sub`), not a uuid.
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
        # The Client is the rejecting actor on the audit trail (Withdraw records
        # the Jeeber; Reject records the Client). Both are opaque text identities.
        actor_id: actor_id,
        action: "reject",
        from_state: prev.status,
        to_state: next.status,
        payload: %{
          "rejected_at" => DateTime.to_iso8601(now),
          "jeeber_id" => next.jeeber_id
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

  # Lock + client-ownership guard. A phantom request id is treated as
  # `:not_found` (the offer row would carry a dangling FK only under data
  # corruption). Only the request CLIENT may reject; everyone else (including
  # the offer's own Jeeber) gets `:forbidden`.
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

    notify_rejected(next)
    {:ok, next}
  end

  defp handle_result({:error, _step, reason, _}, _actor_id) when is_atom(reason),
    do: {:error, reason}

  defp handle_result({:error, _step, %Ecto.Changeset{} = cs, _}, _actor_id), do: {:error, cs}

  # Post-commit, off the request path. A notification failure must never fail a
  # rejection whose DB row is already committed — mirrors the accept saga's
  # fan-out strategy switch.
  defp notify_rejected(%Offer{} = offer) do
    run = fn ->
      NotificationClient.notify(%{
        user_id: offer.jeeber_id,
        event: :offer_rejected,
        payload: %{request_id: offer.request_id, rejected_offer_id: offer.id}
      })
    end

    case Application.get_env(:offer_service, :fanout_strategy, :async) do
      :sync -> run.()
      :async -> Task.Supervisor.start_child(OfferService.TaskSupervisor, run)
    end

    :ok
  end
end
