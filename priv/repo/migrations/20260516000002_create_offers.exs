defmodule OfferService.Repo.Migrations.CreateOffers do
  use Ecto.Migration

  def change do
    create table(:offers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :request_id, references(:requests, type: :uuid, on_delete: :delete_all), null: false

      add :jeeber_id, :uuid, null: false
      add :fee_cents, :integer, null: false
      add :eta_minutes, :integer, null: false
      add :note, :text
      add :status, :string, null: false, default: "pending"
      add :lock_version, :integer, null: false, default: 1
      add :accepted_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:offers, [:request_id])
    create index(:offers, [:jeeber_id])
    create unique_index(:offers, [:request_id, :jeeber_id])

    create constraint(:offers, :offers_status_valid,
             check: "status IN ('pending','accepted','rejected','withdrawn')"
           )

    create constraint(:offers, :offers_fee_positive, check: "fee_cents >= 100")
    create constraint(:offers, :offers_eta_positive, check: "eta_minutes > 0")

    create unique_index(:offers, [:request_id],
             where: "status = 'accepted'",
             name: :offers_one_accepted_per_request
           )
  end
end
