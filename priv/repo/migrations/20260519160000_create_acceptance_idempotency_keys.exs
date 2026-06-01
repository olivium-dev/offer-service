defmodule OfferService.Repo.Migrations.CreateAcceptanceIdempotencyKeys do
  use Ecto.Migration

  @moduledoc """
  T-BE-013 / JEB-49 (AC2 - idempotency).

  When the Client (or its mobile retry mechanism) re-POSTs the same
  `Accept` call with the same `Idempotency-Key` header, the server MUST
  return the exact response previously returned for that key, without
  performing any new side effect (no second OTP, no second chat thread,
  no duplicate push notifications).

  Implementation choice: a small `acceptance_idempotency_keys` table
  scoped on `(client_id, request_id, idempotency_key)` so:

    * The same key replayed by the same actor on the same request is a
      pure replay.
    * The same key reused across actors or requests is NOT honoured —
      it cannot collide with another flow because of the composite
      `unique_index`.

  The cached response is stored as a JSONB column. The hashed shape of
  the request body is also kept so that we can return `422` if the same
  key is later replayed with a divergent payload (the standard
  idempotency-replay contract).
  """

  def change do
    create table(:acceptance_idempotency_keys, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :idempotency_key, :string, null: false
      add :client_id, :uuid, null: false
      add :request_id, references(:requests, type: :uuid, on_delete: :delete_all), null: false
      add :offer_id, references(:offers, type: :uuid, on_delete: :nilify_all)

      add :request_fingerprint, :string, null: false
      add :response, :map, null: false
      add :status, :string, null: false, default: "succeeded"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:acceptance_idempotency_keys,
             [:client_id, :request_id, :idempotency_key],
             name: :acceptance_idem_uniq
           )

    create index(:acceptance_idempotency_keys, [:request_id])

    create constraint(:acceptance_idempotency_keys, :acceptance_idem_status_valid,
             check: "status IN ('succeeded','failed')"
           )
  end
end
