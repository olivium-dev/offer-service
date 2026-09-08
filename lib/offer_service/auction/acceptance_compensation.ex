defmodule OfferService.Auction.AcceptanceCompensation do
  @moduledoc """
  Compensates one accepted-auction generation when delivery-service refuses the
  canonical jeeber assignment.

  The gateway accepts an offer before it can atomically claim delivery-service's
  row. A 4xx claim refusal must not leave a winner accepted in offer-service or
  projected as assigned in the gateway. This module is the narrowly-scoped saga
  counterpart: it verifies the exact accept generation by its opaque token,
  restores the target and only those sibling offers the accept changed, reopens
  the request, and removes the successful accept's idempotency record in ONE
  transaction.

  A compensation audit event makes retries idempotent. Most importantly, the
  generation token means an old delayed retry cannot undo a newer acceptance
  which happens to re-use the gateway's stable Idempotency-Key.
  """

  import Ecto.Query

  alias OfferService.Auction.{AcceptanceIdempotencyKey, Offer, OfferEvent, Request}
  alias OfferService.Repo

  @type result ::
          {:ok, :compensated | :replay}
          | {:error,
             :not_found
             | :forbidden
             | :accept_not_compensable
             | :accept_not_current
             | :concurrent_modification}

  @spec run(binary(), Ecto.UUID.t(), Ecto.UUID.t(), binary(), Ecto.UUID.t()) :: result()
  def run(actor_id, request_id, offer_id, accept_idempotency_key, acceptance_token)
      when is_binary(actor_id) and is_binary(request_id) and is_binary(offer_id) and
             is_binary(accept_idempotency_key) and is_binary(acceptance_token) do
    case Repo.transaction(fn ->
           case compensate(
                  actor_id,
                  request_id,
                  offer_id,
                  accept_idempotency_key,
                  acceptance_token
                ) do
             {:ok, _} = ok -> ok
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :concurrent_modification}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :concurrent_modification}
  end

  defp compensate(actor_id, request_id, offer_id, accept_key, token) do
    with {:ok, request} <- lock_request(request_id, actor_id) do
      case prior_compensation(request_id, offer_id, token) do
        %OfferEvent{} ->
          # The first invocation committed the restore and audit together. A
          # retry is therefore safe even after a later, unrelated re-accept.
          {:ok, :replay}

        nil ->
          compensate_current_accept(request, actor_id, offer_id, accept_key, token)
      end
    end
  end

  defp lock_request(request_id, actor_id) do
    case Repo.one(from r in Request, where: r.id == ^request_id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      %Request{client_id: ^actor_id} = request -> {:ok, request}
      %Request{} -> {:error, :forbidden}
    end
  end

  defp prior_compensation(request_id, offer_id, token) do
    Repo.one(
      from e in OfferEvent,
        where:
          e.request_id == ^request_id and e.offer_id == ^offer_id and
            e.action == "accept_compensated" and
            fragment("?->>'acceptance_token' = ?", e.payload, ^token),
        limit: 1
    )
  end

  defp compensate_current_accept(request, actor_id, offer_id, accept_key, token) do
    with {:ok, idem} <- load_accept_generation(request.id, actor_id, offer_id, accept_key, token),
         :ok <- ensure_current_accept(request, offer_id),
         {:ok, target} <- lock_target(request.id, offer_id),
         :ok <- ensure_accepted_target(target),
         {:ok, accept_event} <- latest_accept_event(request.id, offer_id),
         {:ok, sibling_events} <- sibling_rejection_events(request.id, offer_id, accept_event),
         {:ok, restored_target} <- restore_offer(target, accept_event.from_state),
         {:ok, restored_siblings} <- restore_siblings(sibling_events),
         {:ok, _request} <- Repo.update(Request.reopen_after_compensation_changeset(request)),
         {:ok, _idem} <- Repo.delete(idem),
         {:ok, _audit} <-
           insert_audit(
             request,
             restored_target,
             restored_siblings,
             actor_id,
             accept_key,
             token
           ) do
      {:ok, :compensated}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :concurrent_modification}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :concurrent_modification}
    end
  end

  defp load_accept_generation(request_id, actor_id, offer_id, accept_key, token) do
    case Repo.one(
           from k in AcceptanceIdempotencyKey,
             where:
               k.request_id == ^request_id and k.client_id == ^actor_id and
                 k.offer_id == ^offer_id and k.idempotency_key == ^accept_key and
                 k.compensation_token == ^token and k.status == "succeeded",
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :accept_not_compensable}
      %AcceptanceIdempotencyKey{} = idem -> {:ok, idem}
    end
  end

  defp ensure_current_accept(%Request{status: "accepted", accepted_offer_id: offer_id}, offer_id),
    do: :ok

  defp ensure_current_accept(_request, _offer_id), do: {:error, :accept_not_current}

  defp lock_target(request_id, offer_id) do
    case Repo.one(
           from o in Offer,
             where: o.request_id == ^request_id and o.id == ^offer_id,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :not_found}
      %Offer{} = offer -> {:ok, offer}
    end
  end

  defp ensure_accepted_target(%Offer{status: "accepted"}), do: :ok
  defp ensure_accepted_target(_offer), do: {:error, :accept_not_current}

  defp latest_accept_event(request_id, offer_id) do
    case Repo.one(
           from e in OfferEvent,
             where:
               e.request_id == ^request_id and e.offer_id == ^offer_id and e.action == "accept",
             order_by: [desc: e.inserted_at],
             limit: 1
         ) do
      %OfferEvent{from_state: state} = event when state in ["pending", "submitted", "edited"] ->
        {:ok, event}

      _ ->
        # Do not guess a restoration state from a partial/corrupt audit trail.
        {:error, :accept_not_compensable}
    end
  end

  defp sibling_rejection_events(request_id, accepted_offer_id, accept_event) do
    events =
      Repo.all(
        from e in OfferEvent,
          where:
            e.request_id == ^request_id and e.action == "reject" and
              e.inserted_at >= ^accept_event.inserted_at and
              fragment("?->>'sibling_of' = ?", e.payload, ^accepted_offer_id),
          order_by: [asc: e.inserted_at]
      )

    if Enum.uniq_by(events, & &1.offer_id) == events and
         Enum.all?(events, &(&1.from_state in ["pending", "submitted", "edited"])) do
      {:ok, events}
    else
      # Multiple audit rows for one sibling or an impossible prior state means
      # there is no safe exact inverse. Roll the whole compensation back.
      {:error, :accept_not_compensable}
    end
  end

  defp restore_offer(%Offer{} = offer, prior_status) do
    Repo.update(Offer.restore_from_acceptance_changeset(offer, prior_status))
  end

  defp restore_siblings(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, restored} ->
      case Repo.one(from o in Offer, where: o.id == ^event.offer_id, lock: "FOR UPDATE") do
        %Offer{status: "rejected"} = offer ->
          case restore_offer(offer, event.from_state) do
            {:ok, restored_offer} -> {:cont, {:ok, [restored_offer | restored]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          # A sibling changed after acceptance. Do not overwrite somebody
          # else's mutation just to force a rollback.
          {:halt, {:error, :accept_not_current}}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _} = error -> error
    end
  end

  defp insert_audit(request, restored_target, restored_siblings, actor_id, accept_key, token) do
    OfferEvent.new_changeset(%{
      offer_id: restored_target.id,
      request_id: request.id,
      actor_id: actor_id,
      action: "accept_compensated",
      from_state: "accepted",
      to_state: restored_target.status,
      payload: %{
        "acceptance_token" => token,
        "accept_idempotency_key" => accept_key,
        "restored_sibling_offer_ids" => Enum.map(restored_siblings, & &1.id)
      },
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
