defmodule OfferService.Auction.AuditLog do
  @moduledoc """
  Inserts append-only audit rows into `offer_events` and emits a
  `[:offer, :transition]` telemetry event for every business action.

  Designed to be composed inside `Ecto.Multi` chains so the audit row
  commits in the same transaction as the offer mutation — there is no
  legal way to mutate an offer's state without leaving a trail.

  Telemetry contract (consumed by PromEx via `OfferService.Metrics`):

      :telemetry.execute(
        [:offer, :transition],
        %{system_time: System.system_time()},
        %{action: action, from: from, to: to,
          offer_id: offer_id, request_id: request_id, actor_id: actor_id}
      )
  """

  alias Ecto.Multi
  alias OfferService.Auction.OfferEvent
  alias OfferService.Repo

  @typedoc "Business action name as persisted in `offer_events.action`."
  @type action :: :submit | :edit | :withdraw | :accept | :reject | :expire

  @type entry :: %{
          offer_id: Ecto.UUID.t(),
          request_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          action: action(),
          from_state: nil | binary(),
          to_state: binary(),
          payload: map()
        }

  @doc """
  Append an audit-log step to an `Ecto.Multi`. The step is keyed
  `{:audit, action}` so multiple audit writes can coexist in one Multi.
  """
  @spec multi_log(Multi.t(), entry()) :: Multi.t()
  def multi_log(%Multi{} = multi, %{action: action} = entry) do
    Multi.insert(multi, {:audit, action}, OfferEvent.new_changeset(to_attrs(entry)))
  end

  @doc """
  Persist an audit row outside of a Multi. Use only from non-transactional
  callers (the standard path uses `multi_log/2`).
  """
  @spec log!(entry()) :: OfferEvent.t()
  def log!(entry) do
    entry |> to_attrs() |> OfferEvent.new_changeset() |> Repo.insert!()
  end

  @doc """
  Emit a `[:offer, :transition]` telemetry event. Safe to call after the
  transaction commits — if the event handler crashes the offer mutation
  has already been persisted.
  """
  @spec emit_telemetry(entry()) :: :ok
  def emit_telemetry(%{action: action, from_state: from, to_state: to} = entry) do
    :telemetry.execute(
      [:offer, :transition],
      %{system_time: System.system_time(), count: 1},
      %{
        action: action,
        from: from,
        to: to,
        offer_id: entry.offer_id,
        request_id: entry.request_id,
        actor_id: entry.actor_id
      }
    )

    :ok
  end

  # --- internal ------------------------------------------------------------

  defp to_attrs(entry) do
    %{
      offer_id: entry.offer_id,
      request_id: entry.request_id,
      actor_id: entry.actor_id,
      action: Atom.to_string(entry.action),
      from_state: entry.from_state,
      to_state: entry.to_state,
      payload: entry.payload || %{},
      inserted_at: DateTime.utc_now()
    }
  end
end
