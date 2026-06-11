defmodule OfferService.Auction.Withdraw do
  @moduledoc """
  Implements `DELETE /api/v1/requests/:request_id/offers/:offer_id`.

  Marks an offer as `withdrawn` so it can no longer be edited or accepted.
  Idempotent: re-withdrawing a withdrawn offer returns
  `{:error, :offer_withdrawn}` (HTTP 410) rather than a different error,
  matching AC4 of T-BE-012.

  Guards (in order):

    1. Request + offer exist and offer belongs to request (`:not_found`).
    2. `actor_id == offer.actor_id` (`:forbidden`).
    3. `StateMachine.apply/2` permits `:withdraw` from current state.

  Side-effects inside the transaction:

    * Update offer (`status: "withdrawn"`, `withdrawn_at: now`).
    * Insert `offer_events` row with `action: "withdraw"`.

  Post-commit: emit `[:offer, :transition]` telemetry.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, StateMachine}
  alias OfferService.Repo

  @type error_reason ::
          :not_found
          | :forbidden
          | :offer_withdrawn
          | :already_accepted
          | :already_rejected
          | :offer_expired
          | :invalid_transition
          | :concurrent_modification

  # actor_id is the opaque external actor identity (gateway JWT `sub`), not a uuid.
  @spec run(actor_id :: binary(), request_id :: Ecto.UUID.t(), offer_id :: Ecto.UUID.t()) ::
          {:ok, Offer.t()} | {:error, error_reason()}
  def run(actor_id, request_id, offer_id)
      when is_binary(actor_id) and is_binary(request_id) and is_binary(offer_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:offer, fn repo, _ -> lock_offer(repo, request_id, offer_id, actor_id) end)
    |> Multi.run(:transition, fn _repo, %{offer: offer} -> validate_transition(offer) end)
    |> Multi.update(:withdrawn_offer, fn %{offer: offer} ->
      Offer.withdraw_changeset(offer, now)
    end)
    |> Multi.insert(:audit, fn %{offer: prev, withdrawn_offer: next} ->
      OfferEvent.new_changeset(%{
        offer_id: next.id,
        request_id: next.request_id,
        actor_id: next.actor_id,
        action: "withdraw",
        from_state: prev.status,
        to_state: next.status,
        payload: %{"withdrawn_at" => DateTime.to_iso8601(now)},
        inserted_at: now
      })
    end)
    |> Repo.transaction()
    |> handle_result()
  rescue
    Ecto.StaleEntryError -> {:error, :concurrent_modification}
  end

  # --- Multi steps ---------------------------------------------------------

  defp lock_offer(repo, request_id, offer_id, actor_id) do
    query =
      from o in Offer,
        where: o.id == ^offer_id and o.request_id == ^request_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, :not_found}
      %Offer{actor_id: ^actor_id} = offer -> {:ok, offer}
      %Offer{} -> {:error, :forbidden}
    end
  end

  defp validate_transition(%Offer{status: status, edits_count: ec}) do
    record = %{state: StateMachine.normalize_state(status), edits_count: ec}

    case StateMachine.apply(record, :withdraw) do
      {:ok, next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- result mapping ------------------------------------------------------

  defp handle_result({:ok, %{offer: prev, withdrawn_offer: next}}) do
    AuditLog.emit_telemetry(%{
      offer_id: next.id,
      request_id: next.request_id,
      actor_id: next.actor_id,
      action: :withdraw,
      from_state: prev.status,
      to_state: next.status
    })

    {:ok, next}
  end

  defp handle_result({:error, _step, reason, _}) when is_atom(reason), do: {:error, reason}
  defp handle_result({:error, _step, %Ecto.Changeset{} = cs, _}), do: {:error, cs}
end
