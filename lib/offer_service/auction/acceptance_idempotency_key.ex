defmodule OfferService.Auction.AcceptanceIdempotencyKey do
  @moduledoc """
  Persistent record of an idempotent `Accept` request.

  `(client_id, request_id, idempotency_key)` is the natural key.

  The `response` map is what the controller serialised on the first
  successful execution. Replays return this verbatim so the client sees
  byte-identical output (the accepted offer id and rejected sibling ids)
  across retries.

  Mismatched-fingerprint replays (same key, different payload) are
  rejected by the application layer rather than silently overwriting
  the cached response — see `OfferService.Auction.Idempotency`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.{Offer, Request}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "acceptance_idempotency_keys" do
    field :idempotency_key, :string
    # External opaque identity — the accepting user's gateway-forwarded JWT
    # `sub` (`x-user-id`), NOT a local uuid. Stored as `text`; see migration
    # 20260520090000_widen_external_identity_columns_to_text.
    field :client_id, :string
    field :request_fingerprint, :string
    field :response, :map
    field :status, :string, default: "succeeded"
    # Opaque per-success generation used by the gateway's compensating action.
    # It is deliberately distinct from Idempotency-Key: after a compensated
    # accept the client may re-use its stable accept key, but a delayed old
    # compensation must never undo that newer acceptance.
    field :compensation_token, :binary_id

    belongs_to :request, Request
    belongs_to :offer, Offer

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec new_changeset(map()) :: Ecto.Changeset.t()
  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :idempotency_key,
      :client_id,
      :request_id,
      :offer_id,
      :request_fingerprint,
      :response,
      :status,
      :compensation_token
    ])
    |> put_change(:compensation_token, compensation_token(attrs))
    |> validate_required([
      :idempotency_key,
      :client_id,
      :request_id,
      :request_fingerprint,
      :response,
      :compensation_token
    ])
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_inclusion(:status, ~w(succeeded failed))
    |> unique_constraint([:client_id, :request_id, :idempotency_key],
      name: :acceptance_idem_uniq
    )
  end

  defp compensation_token(attrs) do
    Map.get(attrs, :compensation_token) ||
      Map.get(attrs, "compensation_token") ||
      Ecto.UUID.generate()
  end
end
