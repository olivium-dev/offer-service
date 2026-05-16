# offer-service

Generic offer/auction service — Elixir/Phoenix, real-time bid management.

Part of the Jeeb MVP (see `T-backend-011` / JEEB-29).

## What it does

Hosts the auction layer for delivery requests:

- Accept a single offer for a request, atomically rejecting all others.
- Generate a 4-digit acceptance OTP (returned once to the Client; only its
  SHA-256 hash is persisted).
- Open a chat thread between Client and Jeeber by calling the chat service.
- Fan out push notifications to all parties via the notification service.

Concurrent acceptance attempts are blocked at two levels: a row-level
`SELECT ... FOR UPDATE` on the request, and `Ecto.Changeset.optimistic_lock/2`
on the `lock_version` column. The whole flow runs inside `Ecto.Multi` so it
commits all-or-nothing.

## Public API

```
POST /api/v1/requests/:request_id/offers/:offer_id/accept
Headers:
  x-user-id: <gateway-forwarded user id>
Body (optional):
  { "confirm_high_fee": true }   # required when fee_cents > 5000

200 →
  {
    "request":  { "id": "...", "status": "accepted", "accepted_offer_id": "...", "chat_thread_id": "..." },
    "accepted_offer": { "id": "...", "jeeber_id": "...", "fee_cents": 2500, "status": "accepted", ... },
    "rejected_offer_ids": ["...", "..."],
    "chat_thread_id": "thread-abc",
    "otp_code": "4271"
  }
```

Error responses use a shared envelope: `{ "error": { "code": "...", "message": "..." } }`.

| Status | Code                       | Cause                                                 |
|--------|----------------------------|-------------------------------------------------------|
| 401    | unauthorized               | Missing `x-user-id` header                            |
| 403    | forbidden                  | Actor is not the request owner                        |
| 404    | not_found                  | Request, offer, or pairing doesn't exist              |
| 409    | conflict                   | Already-closed request, non-pending offer, race loss, or high-fee not confirmed |
| 502    | bad_gateway                | chat-service unreachable (transaction rolled back)    |

## Development

```bash
mix setup           # deps + create db + migrate
mix test            # ExUnit
mix format          # auto-format
mix credo --strict  # lint
mix dialyzer        # type analysis
iex -S mix phx.server
```

Postgres is required for tests; the test database is created/migrated by the
`test` alias.

## Configuration

| Env var                     | Purpose                                  | Default                 |
|-----------------------------|------------------------------------------|-------------------------|
| `DATABASE_URL`              | Postgres URL (prod-only)                 | —                       |
| `SECRET_KEY_BASE`           | Phoenix endpoint signing                 | —                       |
| `CHAT_SERVICE_URL`          | Base URL of chat-service                 | `http://localhost:5000` |
| `NOTIFICATION_SERVICE_URL`  | Base URL of notification-service         | `http://localhost:5001` |
| `INTERNAL_SERVICE_TOKEN`    | Bearer token for service-to-service auth | —                       |
| `PORT`                      | HTTP port                                | `4040`                  |

## Olivium conventions

- Payments stay in `unified_payment_gateway` — this service never touches money
  directly; it only emits the financial trigger (`offer_accepted` event).
- Chat thread provisioning is delegated to `chat-service`.
- Push notifications go through `notification-service`.
- All HTTP responses follow the org error-envelope (`{ "error": { code, message } }`).

See `T-backend-011` for the acceptance criteria this implementation satisfies.
