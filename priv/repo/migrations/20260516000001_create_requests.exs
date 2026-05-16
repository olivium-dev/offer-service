defmodule OfferService.Repo.Migrations.CreateRequests do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto", "DROP EXTENSION IF EXISTS pgcrypto"

    create table(:requests, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :client_id, :uuid, null: false
      add :status, :string, null: false, default: "open"
      add :accepted_offer_id, :uuid
      add :chat_thread_id, :string
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:requests, [:client_id])
    create index(:requests, [:status])

    create constraint(:requests, :requests_status_valid,
             check: "status IN ('open','accepted','cancelled','expired')"
           )
  end
end
