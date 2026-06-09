defmodule OfferService.Auction.Offer do
  use Ecto.Schema
  import Ecto.Changeset

  alias OfferService.Auction.Request

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Includes the legacy `pending` value so historical acceptance rows continue
  # to read while new code emits only the canonical six states.
  @statuses ~w(pending submitted edited withdrawn accepted rejected expired)

  schema "offers" do
    # Generic, product-agnostic identity of the actor that submitted the offer —
    # the gateway-forwarded JWT `sub` (`x-user-id`), an opaque text id, NOT a
    # local uuid. This is the canonical column new code reads/writes.
    field :actor_id, :string

    # DEPRECATED, read-compatible alias of `actor_id`, retained for the existing
    # on-the-wire field name and any sibling consumers that still read the legacy
    # column. Dual-written on insert so old readers keep working; never read by
    # new code. (JEB-1474: kept as a non-breaking alias, not a new column.)
    field :jeeber_id, :string

    # Generic parent reference (mirrors `request_id`). `request_id` remains the
    # foreign key; `parent_id` is the product-agnostic alias, dual-written on
    # insert and backfilled additively.
    field :parent_id, :binary_id

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
    |> cast(attrs, [:request_id, :actor_id, :fee_cents, :eta_minutes, :note])
    |> validate_required([:request_id, :actor_id, :fee_cents, :eta_minutes])
    |> validate_number(:fee_cents, greater_than_or_equal_to: 100)
    |> validate_number(:eta_minutes, greater_than: 0, less_than_or_equal_to: 24 * 60)
    |> validate_length(:note, max: 1_000)
    |> put_change(:status, "submitted")
    |> put_change(:edits_count, 0)
    |> mirror_generic_aliases()
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:actor_id, name: :offers_request_id_jeeber_id_index)
  end

  @doc """
  Changeset for `edit_offer/3` — bumps `edits_count`, sets state to `:edited`,
  and increments the optimistic lock version.

  The edit ceiling is supplied by the caller (`max_edits`) rather than hardcoded
  in the shared service. When `max_edits` is `nil` no upper bound is enforced at
  the schema layer — the consumer owns the policy.
  """
  @spec edit_changeset(t(), map(), pos_integer() | nil) :: Ecto.Changeset.t()
  def edit_changeset(%__MODULE__{edits_count: current} = offer, attrs, max_edits \\ nil) do
    offer
    |> cast(attrs, [:fee_cents, :eta_minutes, :note])
    |> validate_number(:fee_cents, greater_than_or_equal_to: 100)
    |> validate_number(:eta_minutes, greater_than: 0, less_than_or_equal_to: 24 * 60)
    |> validate_length(:note, max: 1_000)
    |> put_change(:status, "edited")
    |> put_change(:edits_count, (current || 0) + 1)
    |> validate_inclusion(:status, @statuses)
    |> maybe_validate_edit_cap(max_edits)
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

  # Dual-write the deprecated legacy alias (so old readers keep working) and the
  # generic parent reference from the canonical columns. New code only reads
  # `actor_id`/`parent_id`.
  defp mirror_generic_aliases(changeset) do
    actor_id = get_field(changeset, :actor_id)
    request_id = get_field(changeset, :request_id)

    changeset
    |> maybe_put(:jeeber_id, actor_id)
    |> maybe_put(:parent_id, request_id)
  end

  defp maybe_put(changeset, _field, nil), do: changeset
  defp maybe_put(changeset, field, value), do: put_change(changeset, field, value)

  defp maybe_validate_edit_cap(changeset, nil), do: changeset

  defp maybe_validate_edit_cap(changeset, max_edits) when is_integer(max_edits) do
    validate_number(changeset, :edits_count, less_than_or_equal_to: max_edits)
  end
end
