defmodule OfferService.Auction.Request do
  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.Offer

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "requests" do
    field :client_id, :binary_id
    field :status, :string, default: "open"
    field :accepted_offer_id, :binary_id
    field :chat_thread_id, :string
    field :lock_version, :integer, default: 1

    has_many :offers, Offer

    timestamps(type: :utc_datetime_usec)
  end

  @spec accept_changeset(t(), %{accepted_offer_id: binary, chat_thread_id: binary | nil}) ::
          Ecto.Changeset.t()
  def accept_changeset(%__MODULE__{} = request, attrs) do
    request
    |> cast(attrs, [:accepted_offer_id, :chat_thread_id])
    |> put_change(:status, "accepted")
    |> validate_required([:accepted_offer_id])
    |> validate_inclusion(:status, ~w(open accepted cancelled expired))
    |> optimistic_lock(:lock_version)
  end
end
