defmodule OfferService.Auction.Offer do
  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.Request

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Includes the legacy `pending` value so JEB-47 acceptance tests continue
  # to pass while new code emits only the canonical six states.
  @statuses ~w(pending submitted edited withdrawn accepted rejected expired)

  schema "offers" do
    # External opaque identity — the submitting Jeeber's gateway-forwarded JWT
    # `sub` (`x-user-id`), NOT a local uuid. Stored as `text`; see migration
    # 20260520090000_widen_external_identity_columns_to_text.
    field :jeeber_id, :string
    field :fee_cents, :integer
    field :eta_minutes, :integer
    field :note, :string
    field :status, :string, default: "submitted"
    field :edits_count, :integer, default: 0
    field :lock_version, :integer, default: 1
    field :accepted_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec

    belongs_to :request, Request

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for `submit_offer/2` — creates an offer in `:submitted` state."
  @spec submit_changeset(map()) :: Ecto.Changeset.t()
  def submit_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:request_id, :jeeber_id, :fee_cents, :eta_minutes, :note])
    |> validate_required([:request_id, :jeeber_id, :fee_cents, :eta_minutes])
    |> validate_number(:fee_cents, greater_than_or_equal_to: 100)
    |> validate_number(:eta_minutes, greater_than: 0, less_than_or_equal_to: 24 * 60)
    |> validate_length(:note, max: 1_000)
    |> put_change(:status, "submitted")
    |> put_change(:edits_count, 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:request_id, :jeeber_id])
  end

  @doc """
  Changeset for `edit_offer/3` — bumps `edits_count`, sets state to `:edited`,
  and increments the optimistic lock version. The hard `edits_count ≤ 2`
  ceiling is enforced both by the application (see `StateMachine.apply/2`)
  and by the DB constraint `offers_edits_count_in_range`.
  """
  @spec edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def edit_changeset(%__MODULE__{edits_count: current} = offer, attrs) do
    offer
    |> cast(attrs, [:fee_cents, :eta_minutes, :note])
    |> validate_number(:fee_cents, greater_than_or_equal_to: 100)
    |> validate_number(:eta_minutes, greater_than: 0, less_than_or_equal_to: 24 * 60)
    |> validate_length(:note, max: 1_000)
    |> put_change(:status, "edited")
    |> put_change(:edits_count, (current || 0) + 1)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:edits_count, less_than_or_equal_to: 2)
    |> optimistic_lock(:lock_version)
  end

  @doc "Changeset for `withdraw_offer/2` — marks the offer terminal."
  @spec withdraw_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def withdraw_changeset(%__MODULE__{} = offer, now) do
    offer
    |> change(status: "withdrawn", withdrawn_at: now)
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  @doc """
  Changeset for the force-expire test-seam — marks the offer terminal
  (`status: "expired"`). The offer schema carries no dedicated `expired_at`
  column (unlike `withdrawn_at`/`accepted_at`); the precise expiry instant is
  captured by the paired `offer_events` audit row (`action: "expire"`) and the
  `[:offer, :transition]` telemetry event, so no migration is required.
  """
  @spec expire_changeset(t()) :: Ecto.Changeset.t()
  def expire_changeset(%__MODULE__{} = offer) do
    offer
    |> change(status: "expired")
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  @doc false
  @spec accept_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def accept_changeset(%__MODULE__{} = offer, now) do
    offer
    |> change(status: "accepted", accepted_at: now)
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  @doc false
  @spec reject_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def reject_changeset(%__MODULE__{} = offer, now) do
    offer
    |> change(status: "rejected", rejected_at: now)
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end
end
