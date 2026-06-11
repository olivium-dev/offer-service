defmodule OfferService.Repo.Migrations.AddGenericOfferIdentityColumns do
  use Ecto.Migration

  @moduledoc """
  JEB-1474 — boundary remediation: give the shared `offers` table
  product-agnostic identity columns.

  The reverse-auction `offers` row historically carried two
  product-specific identity columns: the submitting actor (`actor_id`'s legacy
  alias) and the parent request reference. This migration introduces the
  generic, product-agnostic names so new code never has to read a
  product-taxonomy column name:

    * `actor_id` — the opaque external identity of the actor that submitted the
      offer (the gateway-forwarded JWT `sub`).
    * `parent_id` — the parent resource the offer attaches to (mirrors the
      existing `request_id` foreign key value).

  ## Additive & non-breaking (GR1)

    * Both columns are added nullable, then BACKFILLED from the legacy columns.
    * The legacy columns are LEFT IN PLACE as deprecated, read-compatible
      aliases — nothing is renamed or dropped, so existing readers and the
      on-the-wire `jeeber_id` field keep working verbatim.
    * Idempotent: `add_if_not_exists` / `create_if_not_exists` and a guarded
      backfill let the migration be applied manually more than once safely
      (GR5 — migrations are explicit one-time ops, not auto-run on deploy).
  """

  def up do
    alter table(:offers) do
      add_if_not_exists :actor_id, :text
      add_if_not_exists :parent_id, :uuid
    end

    # Backfill the generic columns from the legacy aliases. Guarded so a re-run
    # only touches rows that have not been backfilled yet.
    execute "UPDATE offers SET actor_id = jeeber_id WHERE actor_id IS NULL"
    execute "UPDATE offers SET parent_id = request_id WHERE parent_id IS NULL"

    create_if_not_exists index(:offers, [:actor_id])
    create_if_not_exists index(:offers, [:parent_id])
  end

  def down do
    drop_if_exists index(:offers, [:parent_id])
    drop_if_exists index(:offers, [:actor_id])

    alter table(:offers) do
      remove_if_exists :parent_id, :uuid
      remove_if_exists :actor_id, :text
    end
  end
end
