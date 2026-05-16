defmodule OfferService.Auction.AcceptanceOtp do
  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.{Offer, Request}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "acceptance_otps" do
    field :code_hash, :binary
    field :code_last2, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    belongs_to :request, Request
    belongs_to :offer, Offer

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Build a changeset for inserting a new acceptance OTP record.

  Only the `code_hash` and the last two characters (for UI affordance) are
  stored — the raw OTP is returned to the caller in-flight and never persisted.
  """
  @spec new_changeset(map()) :: Ecto.Changeset.t()
  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:request_id, :offer_id, :code_hash, :code_last2, :expires_at])
    |> validate_required([:request_id, :offer_id, :code_hash, :code_last2, :expires_at])
    |> validate_length(:code_last2, is: 2)
    |> unique_constraint(:offer_id)
    |> unique_constraint(:request_id)
  end
end
