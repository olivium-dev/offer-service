defmodule OfferService.Repo.Migrations.ExtendOfferStateForCrud do
  use Ecto.Migration

  @moduledoc """
  Extend the `offers` table to support the full state machine required by
  T-BE-012 (submit / edit ≤2x / withdraw / accept) while preserving the
  legacy `pending` value used by the acceptance flow scaffolded in JEB-47.

  After this migration the allowed `status` set is:
      pending      (legacy alias for submitted — never emitted by new code)
      submitted    (created by submit_offer/2)
      edited       (created by edit_offer/3; carries 1 ≤ edits_count ≤ 2)
      withdrawn    (terminal; cannot be accepted)
      accepted     (terminal; winner of advisory-lock race)
      rejected     (terminal; sibling of an accepted offer)
      expired      (terminal; request TTL elapsed)

  We additionally introduce:
    * `edits_count`  — 0 on submit, +1 on every successful edit, capped at 2.
    * `withdrawn_at` — set when an offer transitions to `withdrawn`.

  No index changes are required: `request_id`, `(request_id, jeeber_id)`, and
  the partial unique `offers_one_accepted_per_request` index from migration
  `20260516000002_create_offers.exs` remain semantically correct.
  """

  def up do
    execute("ALTER TABLE offers DROP CONSTRAINT offers_status_valid")

    execute("""
    ALTER TABLE offers
    ADD CONSTRAINT offers_status_valid
    CHECK (status IN (
      'pending', 'submitted', 'edited', 'withdrawn',
      'accepted', 'rejected', 'expired'
    ))
    """)

    alter table(:offers) do
      add :edits_count, :integer, null: false, default: 0
      add :withdrawn_at, :utc_datetime_usec
    end

    execute("""
    ALTER TABLE offers
    ADD CONSTRAINT offers_edits_count_in_range
    CHECK (edits_count >= 0 AND edits_count <= 2)
    """)
  end

  def down do
    execute("ALTER TABLE offers DROP CONSTRAINT offers_edits_count_in_range")

    alter table(:offers) do
      remove :withdrawn_at
      remove :edits_count
    end

    execute("ALTER TABLE offers DROP CONSTRAINT offers_status_valid")

    execute("""
    ALTER TABLE offers
    ADD CONSTRAINT offers_status_valid
    CHECK (status IN ('pending', 'accepted', 'rejected', 'withdrawn'))
    """)
  end
end
