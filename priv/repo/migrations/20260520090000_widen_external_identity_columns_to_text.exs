defmodule OfferService.Repo.Migrations.WidenExternalIdentityColumnsToText do
  use Ecto.Migration

  @moduledoc """
  S07 — widen the four *external opaque identity* columns from `uuid` to `text`.

  ## Why

  `requests.client_id`, `offers.jeeber_id`, `offer_events.actor_id`, and
  `acceptance_idempotency_keys.client_id` do NOT hold ids that this service
  generates. They hold the **caller's identity as forwarded by the Jeeb
  gateway** — the value of the `x-user-id` header, which is the raw JWT `sub`
  the gateway extracts from the user-facing token. That `sub` is an opaque
  string (e.g. `s07-sami-client`, `s07-kamal-jeeber`); it is NOT guaranteed to
  be a UUID, and modelling it as Postgres `uuid` was the bug:

    * `INSERT ... client_id = 's07-sami-client'` -> `22P02 invalid input syntax
      for type uuid` -> 500. This is the proven OS-1 mirror failure
      (`POST /api/v1/requests`) and the identical `Submit` failure on
      `offers.jeeber_id` (the H2 "submit a bid" 500 that gates the whole S07
      auction saga).

  Typing an externally-owned identity as a local `uuid` FK type is a modelling
  error. These columns are NOT foreign keys to any `uuid` primary key in this
  service — they are values we store, compare for equality, and echo back.

  ## Safety — this is a WIDENING, backward-compatible change

    * `uuid -> text USING <col>::text` preserves every existing value verbatim
      (a v4 uuid renders to its canonical 36-char text form, which is still a
      valid, unique text value). No row is lost or rewritten in a lossy way.
    * `NOT NULL` is preserved on every column (no fail-open introduced).
    * JSON serialization is unaffected — these columns already serialise as
      strings on the wire, so existing sibling-product consumers see no change.
    * Reads, equality filters (`where client_id == ^actor_id`), and the
      `(client_id, request_id, idempotency_key)` unique index keep working:
      text equality is the same set of matches as uuid equality for values
      that were valid uuids, and now ALSO matches opaque non-uuid subs.
    * Forward-only. The original create migrations (2026051600000{1,2},
      20260519160000) are NOT edited. `down/0` narrows back to uuid for a clean
      rollback **only when every stored value still parses as a uuid** — if any
      opaque non-uuid sub has been written (the whole point of this change), the
      down cast will fail loudly rather than silently truncate. That is the
      correct, non-destructive rollback contract for a one-way widening.

  Indexes on these columns (`requests.client_id`, `offers.jeeber_id`,
  `offer_events.actor_id`) are preserved automatically by `ALTER COLUMN TYPE`;
  Postgres rebuilds them in place. The tables are tiny (pre-launch), so a plain
  rewrite is correct — `CONCURRENTLY` is neither needed nor valid inside a
  transactional `ALTER TYPE`.
  """

  def up do
    execute "ALTER TABLE requests ALTER COLUMN client_id TYPE text USING client_id::text"
    execute "ALTER TABLE offers ALTER COLUMN jeeber_id TYPE text USING jeeber_id::text"
    execute "ALTER TABLE offer_events ALTER COLUMN actor_id TYPE text USING actor_id::text"

    execute "ALTER TABLE acceptance_idempotency_keys ALTER COLUMN client_id TYPE text USING client_id::text"
  end

  def down do
    # Forward-only in spirit: this only succeeds if every value still parses as
    # a uuid. If an opaque sub was stored, this raises (22P02) — by design.
    execute "ALTER TABLE acceptance_idempotency_keys ALTER COLUMN client_id TYPE uuid USING client_id::uuid"

    execute "ALTER TABLE offer_events ALTER COLUMN actor_id TYPE uuid USING actor_id::uuid"
    execute "ALTER TABLE offers ALTER COLUMN jeeber_id TYPE uuid USING jeeber_id::uuid"
    execute "ALTER TABLE requests ALTER COLUMN client_id TYPE uuid USING client_id::uuid"
  end
end
