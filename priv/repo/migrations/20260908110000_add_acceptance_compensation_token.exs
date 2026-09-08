defmodule OfferService.Repo.Migrations.AddAcceptanceCompensationToken do
  use Ecto.Migration

  @moduledoc """
  Adds the exact-generation token used by the gateway's accept compensation
  saga, and records the new immutable compensation audit action.

  An Idempotency-Key is intentionally reusable after a compensated refusal, so
  it cannot identify an acceptance generation on its own. The UUID token does.
  """

  def up do
    alter table(:acceptance_idempotency_keys) do
      add :compensation_token, :uuid
    end

    execute """
    UPDATE acceptance_idempotency_keys
    SET compensation_token = gen_random_uuid()
    WHERE compensation_token IS NULL
    """

    alter table(:acceptance_idempotency_keys) do
      modify :compensation_token, :uuid, null: false
    end

    create unique_index(:acceptance_idempotency_keys, [:compensation_token],
             name: :acceptance_compensation_token_uniq
           )

    execute "ALTER TABLE offer_events DROP CONSTRAINT IF EXISTS offer_events_action_valid"

    execute """
    ALTER TABLE offer_events
    ADD CONSTRAINT offer_events_action_valid
    CHECK (action IN ('submit','edit','withdraw','accept','reject','expire','accept_compensated'))
    """
  end

  def down do
    execute "ALTER TABLE offer_events DROP CONSTRAINT IF EXISTS offer_events_action_valid"

    execute """
    ALTER TABLE offer_events
    ADD CONSTRAINT offer_events_action_valid
    CHECK (action IN ('submit','edit','withdraw','accept','reject','expire'))
    """

    drop index(:acceptance_idempotency_keys, [:compensation_token],
           name: :acceptance_compensation_token_uniq
         )

    alter table(:acceptance_idempotency_keys) do
      remove :compensation_token
    end
  end
end
