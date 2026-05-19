defmodule OfferService.Repo.Migrations.CreateOfferEvents do
  use Ecto.Migration

  @moduledoc """
  Append-only audit log for every offer state transition (submit, edit,
  withdraw, accept). Required by T-BE-012 AC for traceability of the
  auction lifecycle.

  No `updated_at` is recorded by design — these rows are immutable.
  """

  def change do
    create table(:offer_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :offer_id, references(:offers, type: :uuid, on_delete: :delete_all), null: false
      add :request_id, references(:requests, type: :uuid, on_delete: :delete_all), null: false

      add :actor_id, :uuid, null: false
      add :action, :string, null: false
      add :from_state, :string
      add :to_state, :string, null: false
      add :payload, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:offer_events, [:offer_id])
    create index(:offer_events, [:request_id])
    create index(:offer_events, [:actor_id])
    create index(:offer_events, [:inserted_at])

    create constraint(:offer_events, :offer_events_action_valid,
             check: "action IN ('submit','edit','withdraw','accept','reject','expire')"
           )
  end
end
