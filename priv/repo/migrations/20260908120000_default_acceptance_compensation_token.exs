defmodule OfferService.Repo.Migrations.DefaultAcceptanceCompensationToken do
  use Ecto.Migration

  @moduledoc """
  Keeps the acceptance table write-compatible with the immediately previous
  application release during a rollback.

  The compensation-aware release supplies its own generation token. Older
  releases omit the column, so PostgreSQL must generate the token for those
  inserts while the NOT NULL constraint is present.
  """

  def up do
    execute """
    ALTER TABLE acceptance_idempotency_keys
    ALTER COLUMN compensation_token SET DEFAULT gen_random_uuid()
    """
  end
end
