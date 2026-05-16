defmodule OfferService.Auction.Offer do
  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.Request

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending accepted rejected withdrawn)

  schema "offers" do
    field :jeeber_id, :binary_id
    field :fee_cents, :integer
    field :eta_minutes, :integer
    field :note, :string
    field :status, :string, default: "pending"
    field :lock_version, :integer, default: 1
    field :accepted_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec

    belongs_to :request, Request

    timestamps(type: :utc_datetime_usec)
  end

  @spec accept_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def accept_changeset(%__MODULE__{} = offer, now) do
    offer
    |> change(status: "accepted", accepted_at: now)
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  @spec reject_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def reject_changeset(%__MODULE__{} = offer, now) do
    offer
    |> change(status: "rejected", rejected_at: now)
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end
end
