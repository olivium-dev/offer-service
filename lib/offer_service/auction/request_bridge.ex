defmodule OfferService.Auction.RequestBridge do
  @moduledoc """
  Implements the gateway request-bridge: `POST /api/v1/requests`.

  ## Why this exists

  The gateway is the system-of-record for a request. A request is created in
  the gateway (`POST /requests`) and gets an id there. Offers,
  however, are owned by this service and are submitted against that
  `request_id` (`POST /api/v1/requests/:request_id/offers`).
  `Submit.lock_request/2` locks the `requests` row `FOR UPDATE` and **requires
  it to already exist** — otherwise it returns `:not_found`, which the gateway
  was surfacing as a raw 500.

  This module lets the gateway mirror a freshly-created request into
  offer-service so subsequent submits resolve. It is the only write path for
  the `requests` table outside the accept saga.

  ## Idempotency & safety

  The mirror is an **idempotent insert keyed on the caller-supplied `id`**:

    * First call for an `id` inserts an `open` request and returns `{:ok,
      :created, request}`.
    * Any subsequent call for the same `id` is a no-op via `on_conflict:
      :nothing` and returns `{:ok, :exists, request}` with the **persisted**
      row re-read from the database.

  Crucially, a re-mirror **never updates** `status`, `accepted_offer_id`,
  `chat_thread_id`, or `lock_version`. Those columns are owned by the accept
  saga (`Acceptance`). If the gateway re-sends a request that has already
  transitioned to `accepted`/`expired`/`cancelled`, the existing lifecycle
  state is preserved — a late, best-effort mirror call can never resurrect a
  closed auction or clobber an in-flight acceptance.
  """

  import Ecto.Query

  alias OfferService.Auction.Request
  alias OfferService.Repo

  @type upsert_attrs :: %{
          required(:id) => Ecto.UUID.t(),
          # Opaque external identity (gateway JWT `sub`), not necessarily a uuid.
          required(:client_id) => binary(),
          optional(:status) => binary()
        }

  @type error_reason :: :invalid_id | Ecto.Changeset.t()

  @doc """
  Idempotently mirror a gateway-created request.

  Returns `{:ok, :created, request}` on first insert, `{:ok, :exists,
  request}` on a replay, or `{:error, reason}` when the payload is invalid.
  """
  @spec upsert(map()) :: {:ok, :created | :exists, Request.t()} | {:error, error_reason()}
  def upsert(attrs) when is_map(attrs) do
    normalized = normalize(attrs)

    with {:ok, id} <- fetch_id(normalized) do
      changeset = Request.upsert_changeset(normalized)

      if changeset.valid? do
        do_upsert(changeset, id)
      else
        {:error, changeset}
      end
    end
  end

  # --- internals -----------------------------------------------------------

  defp do_upsert(changeset, id) do
    # If the row already exists, return it untouched (`:exists`) — a re-mirror
    # must never reset lifecycle columns owned by the accept saga.
    case Repo.one(from r in Request, where: r.id == ^id) do
      %Request{} = existing ->
        {:ok, :exists, existing}

      nil ->
        insert_new(changeset, id)
    end
  end

  # Attempt the insert. The primary-key uniqueness on `id` is the race guard:
  # if a concurrent request mirrored the same id between our existence check
  # and this insert, `on_conflict: :nothing` suppresses the duplicate and we
  # re-read the now-persisted row, reporting `:exists`.
  defp insert_new(changeset, id) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :id, returning: false) do
      {:ok, _struct} ->
        # Re-read to obtain the authoritative persisted row regardless of
        # whether our insert won or a concurrent insert did.
        request = Repo.one!(from r in Request, where: r.id == ^id)
        {:ok, :created, request}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  # Accept both atom- and string-keyed maps (controllers pass string keys).
  defp normalize(attrs) do
    %{
      id: attrs[:id] || attrs["id"] || attrs[:request_id] || attrs["request_id"],
      client_id: attrs[:client_id] || attrs["client_id"],
      status: attrs[:status] || attrs["status"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp fetch_id(%{id: id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_id}
    end
  end

  defp fetch_id(_), do: {:error, :invalid_id}
end
