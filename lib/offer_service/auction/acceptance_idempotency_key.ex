defmodule OfferService.Auction.AcceptanceIdempotencyKey do
  @moduledoc """
  Persistent record of an idempotent `Accept` request.

  `(client_id, request_id, idempotency_key)` is the natural key.

  The `response` map is what the controller serialised on the first
  successful execution. Replays return this verbatim so the client sees
  byte-identical output and `chat_thread_id` / `otp_code` / `delivery_id`
  remain stable across retries.

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
      :status
    ])
    |> validate_required([
      :idempotency_key,
      :client_id,
      :request_id,
      :request_fingerprint,
      :response
    ])
    |> validate_length(:idempotency_key, min: 8, max: 128)
    |> validate_inclusion(:status, ~w(succeeded failed))
    |> unique_constraint([:client_id, :request_id, :idempotency_key],
      name: :acceptance_idem_uniq
    )
  end
end
