defmodule OfferService.Repo.Migrations.MakeOfferEditCapConfigurable do
  use Ecto.Migration

  @moduledoc """
  JEB-1474 — de-hardcode the offer edit cap in the shared service.

  The shared service previously baked a product-specific edit ceiling
  (`edits_count <= 2`) into a DB CHECK constraint
  (`offers_edits_count_in_range`). The literal `2` is a product policy and must
  not live in the reusable service — it now lives in the consuming gateway,
  which supplies `max_edits` per request, with the service falling back to a
  configurable `:max_edits` value.

  This migration drops the hard `<= 2` ceiling and replaces it with a
  non-negativity invariant only, so:

    * existing rows are never broken (any row with `edits_count <= 2` already
      satisfies `>= 0`; no row is rewritten or rejected);
    * the cap becomes an application/config concern (configurable `max_edits`),
      not a schema constant;
    * the only DB-level invariant retained is the genuinely generic one
      (`edits_count` is a non-negative counter).

  ## Additive / idempotent (GR1, GR5)

  `DROP CONSTRAINT IF EXISTS` for both the old and the new constraint name makes
  the migration safe to apply manually more than once. The replacement
  constraint is generic and product-agnostic.
  """

  def up do
    execute "ALTER TABLE offers DROP CONSTRAINT IF EXISTS offers_edits_count_in_range"
    execute "ALTER TABLE offers DROP CONSTRAINT IF EXISTS offers_edits_count_non_negative"

    execute """
    ALTER TABLE offers
    ADD CONSTRAINT offers_edits_count_non_negative
    CHECK (edits_count >= 0)
    """
  end

  def down do
    execute "ALTER TABLE offers DROP CONSTRAINT IF EXISTS offers_edits_count_non_negative"
    execute "ALTER TABLE offers DROP CONSTRAINT IF EXISTS offers_edits_count_in_range"

    execute """
    ALTER TABLE offers
    ADD CONSTRAINT offers_edits_count_in_range
    CHECK (edits_count >= 0 AND edits_count <= 2)
    """
  end
end
