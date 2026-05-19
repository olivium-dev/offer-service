defmodule OfferService.Auction.OfferEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.{Offer, Request}

  @moduledoc """
  Append-only audit row for every offer state transition.

  One row per business action (submit, edit, withdraw, accept, reject,
  expire). `payload` carries a snapshot of the *changed* fields so the
  before/after can be reconstructed without re-deriving from production
  Postgres logs.
  """

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actions ~w(submit edit withdraw accept reject expire)

  schema "offer_events" do
    field :actor_id, :binary_id
    field :action, :string
    field :from_state, :string
    field :to_state, :string
    field :payload, :map, default: %{}
    field :inserted_at, :utc_datetime_usec

    belongs_to :offer, Offer
    belongs_to :request, Request
  end

  @spec new_changeset(map()) :: Ecto.Changeset.t()
  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :offer_id,
      :request_id,
      :actor_id,
      :action,
      :from_state,
      :to_state,
      :payload,
      :inserted_at
    ])
    |> validate_required([:offer_id, :request_id, :actor_id, :action, :to_state, :inserted_at])
    |> validate_inclusion(:action, @actions)
  end
end
