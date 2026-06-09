defmodule OfferService.Auction.Edit do
  @moduledoc """
  Implements `PUT /api/v1/requests/:request_id/offers/:offer_id`.

  Allows the offer's owning actor to refine `fee_cents`, `eta_minutes`, and
  `note` up to a configurable `max_edits` ceiling. Exceeding it returns
  `{:error, :edit_limit_reached}` mapped by the fallback controller to
  HTTP 422 `edit_limit_reached`.

  The edit ceiling is NOT hardcoded in this shared service: the caller may
  supply `max_edits` in the attrs, otherwise it falls back to the configurable
  `:max_edits` application env (`nil` = no service-imposed ceiling).

  Guards (in order):

    1. Request and offer exist (`:not_found`).
    2. Offer belongs to `request_id` (`:not_found`).
    3. `actor_id == offer.actor_id` (`:forbidden`).
    4. Offer's current state allows `:edit` per `StateMachine` — terminal
       states (`withdrawn`, `accepted`, `rejected`, `expired`) reject.
    5. `edits_count < max_edits` (`:edit_limit_reached`).

  All checks are performed inside a single transaction. The offer row is
  locked with `SELECT ... FOR UPDATE` so two concurrent edits cannot both
  succeed and double-increment `edits_count`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, StateMachine}
  alias OfferService.Repo

  @type edit_attrs :: %{
          optional(:fee_cents) => non_neg_integer(),
          optional(:eta_minutes) => non_neg_integer(),
          optional(:note) => binary(),
          optional(:max_edits) => pos_integer()
        }

  @type error_reason ::
          :not_found
          | :forbidden
          | :edit_limit_reached
          | :offer_withdrawn
          | :already_accepted
          | :already_rejected
          | :offer_expired
          | :invalid_transition
          | :concurrent_modification
          | Ecto.Changeset.t()

  # actor_id is the opaque external actor identity (gateway JWT `sub`), not a uuid.
  @spec run(actor_id :: binary(), request_id :: Ecto.UUID.t(), offer_id :: Ecto.UUID.t(), map()) ::
          {:ok, Offer.t()} | {:error, error_reason()}
  def run(actor_id, request_id, offer_id, attrs)
      when is_binary(actor_id) and is_binary(request_id) and is_binary(offer_id) do
    max_edits = resolve_max_edits(attrs)

    Multi.new()
    |> Multi.run(:offer, fn repo, _ -> lock_offer(repo, request_id, offer_id, actor_id) end)
    |> Multi.run(:transition, fn _repo, %{offer: offer} ->
      validate_transition(offer, max_edits)
    end)
    |> Multi.update(:edited_offer, fn %{offer: offer} ->
      Offer.edit_changeset(offer, attrs, max_edits)
    end)
    |> Multi.insert(:audit, fn %{offer: prev, edited_offer: next} ->
      OfferEvent.new_changeset(%{
        offer_id: next.id,
        request_id: next.request_id,
        actor_id: next.actor_id,
        action: "edit",
        from_state: prev.status,
        to_state: next.status,
        payload: %{
          "edits_count" => next.edits_count,
          "before" => %{
            "fee_cents" => prev.fee_cents,
            "eta_minutes" => prev.eta_minutes,
            "note" => prev.note
          },
          "after" => %{
            "fee_cents" => next.fee_cents,
            "eta_minutes" => next.eta_minutes,
            "note" => next.note
          }
        },
        inserted_at: DateTime.utc_now()
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

  defp validate_transition(%Offer{status: status, edits_count: ec}, max_edits) do
    record = %{state: StateMachine.normalize_state(status), edits_count: ec}

    case StateMachine.apply(record, :edit, max_edits) do
      {:ok, next} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  # The edit ceiling is caller-supplied (gateway-driven). Accept an explicit
  # `max_edits` in the attrs (atom- or string-keyed); otherwise fall back to the
  # configurable `:max_edits` application env (`nil` = no service-imposed cap).
  defp resolve_max_edits(attrs) do
    case attrs[:max_edits] || attrs["max_edits"] do
      n when is_integer(n) and n > 0 -> n
      _ -> StateMachine.max_edits()
    end
  end

  # --- result mapping ------------------------------------------------------

  defp handle_result({:ok, %{offer: prev, edited_offer: next}}) do
    AuditLog.emit_telemetry(%{
      offer_id: next.id,
      request_id: next.request_id,
      actor_id: next.actor_id,
      action: :edit,
      from_state: prev.status,
      to_state: next.status
    })

    {:ok, next}
  end

  defp handle_result({:error, _step, reason, _}) when is_atom(reason), do: {:error, reason}
  defp handle_result({:error, _step, %Ecto.Changeset{} = cs, _}), do: {:error, cs}
end
