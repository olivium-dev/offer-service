defmodule OfferService.Auction.Submit do
  @moduledoc """
  Implements `POST /api/v1/requests/:request_id/offers`.

  A Jeeber submits a new offer (price, ETA, optional note) against an open
  request. The request row is locked `FOR UPDATE` for the duration of the
  transaction so that a concurrent close-of-auction cannot interleave
  between the request-status read and the offer insert.

  Guards:

    * Request must exist (`:not_found`).
    * Request must be in `open` status — the JEB-47 schema's persisted
      name for "searching". Any other status returns `:request_not_open`.
    * `(request_id, jeeber_id)` is unique — a re-submit returns
      `:already_submitted`.

  Side-effects (all in the same transaction as the offer insert):

    * Inserts an `offer_events` audit row with `action: "submit"`.

  Post-commit:

    * Emits `[:offer, :transition]` telemetry with `from: nil, to: "submitted"`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias OfferService.Auction.{AuditLog, Offer, OfferEvent, Request, StateMachine}
  alias OfferService.Repo

  @type submit_attrs :: %{
          required(:fee_cents) => non_neg_integer(),
          required(:eta_minutes) => non_neg_integer(),
          optional(:note) => binary()
        }

  @type error_reason ::
          :not_found
          | :request_not_open
          | :already_submitted
          | Ecto.Changeset.t()

  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, Offer.t()} | {:error, error_reason()}
  def run(actor_id, request_id, attrs) when is_binary(actor_id) and is_binary(request_id) do
    initial = StateMachine.initial()

    Multi.new()
    |> Multi.run(:request, fn repo, _ -> lock_request(repo, request_id) end)
    |> Multi.insert(:offer, fn _ ->
      %{
        request_id: request_id,
        jeeber_id: actor_id,
        fee_cents: attrs[:fee_cents] || attrs["fee_cents"],
        eta_minutes: attrs[:eta_minutes] || attrs["eta_minutes"],
        note: attrs[:note] || attrs["note"]
      }
      |> Offer.submit_changeset()
      |> Ecto.Changeset.put_change(:status, Atom.to_string(initial.state))
      |> Ecto.Changeset.put_change(:edits_count, initial.edits_count)
    end)
    |> Multi.insert(:audit, fn %{offer: offer, request: req} ->
      OfferEvent.new_changeset(%{
        offer_id: offer.id,
        request_id: req.id,
        actor_id: offer.jeeber_id,
        action: "submit",
        from_state: nil,
        to_state: offer.status,
        payload: %{
          "fee_cents" => offer.fee_cents,
          "eta_minutes" => offer.eta_minutes,
          "note" => offer.note
        },
        inserted_at: DateTime.utc_now()
      })
    end)
    |> Repo.transaction()
    |> handle_result()
  end

  # --- Multi steps ---------------------------------------------------------

  defp lock_request(repo, request_id) do
    query =
      from r in Request,
        where: r.id == ^request_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, :not_found}
      %Request{status: "open"} = req -> {:ok, req}
      %Request{} -> {:error, :request_not_open}
    end
  end

  # --- result mapping ------------------------------------------------------

  defp handle_result({:ok, %{offer: offer, request: req}}) do
    AuditLog.emit_telemetry(%{
      offer_id: offer.id,
      request_id: req.id,
      actor_id: offer.jeeber_id,
      action: :submit,
      from_state: nil,
      to_state: offer.status
    })

    {:ok, offer}
  end

  defp handle_result({:error, :request, reason, _}) when is_atom(reason), do: {:error, reason}

  defp handle_result({:error, :offer, %Ecto.Changeset{errors: errors} = cs, _}) do
    case Keyword.get(errors, :request_id) || Keyword.get(errors, :jeeber_id) do
      {_msg, [constraint: :unique, constraint_name: "offers_request_id_jeeber_id_index"]} ->
        {:error, :already_submitted}

      _ ->
        {:error, cs}
    end
  end

  defp handle_result({:error, _step, reason, _}) when is_atom(reason), do: {:error, reason}
  defp handle_result({:error, _step, %Ecto.Changeset{} = cs, _}), do: {:error, cs}
end
