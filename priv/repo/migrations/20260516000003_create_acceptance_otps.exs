defmodule OfferService.Repo.Migrations.CreateAcceptanceOtps do
  use Ecto.Migration

  def change do
    create table(:acceptance_otps, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :request_id,
          references(:requests, type: :uuid, on_delete: :delete_all),
          null: false

      add :offer_id, references(:offers, type: :uuid, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      add :code_last2, :string, null: false, size: 2
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:acceptance_otps, [:offer_id])
    create unique_index(:acceptance_otps, [:request_id])
  end
end
