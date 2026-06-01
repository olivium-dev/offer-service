ARG ELIXIR_VERSION=1.17.3
# OTP/DEBIAN bumped 2026-06-01: the prior hexpm combo
# (27.1.2 / bookworm-20241016-slim) was garbage-collected from Docker Hub
# ("not found"). 27.3.4.12 / bookworm-20260518-slim is a currently-published
# hexpm/elixir tag. Runtime debian pinned separately to a live library tag.
ARG OTP_VERSION=27.3.4.12
ARG DEBIAN_VERSION=bookworm-20260518-slim
ARG RUNTIME_DEBIAN_VERSION=bookworm-20251229-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS builder

ENV MIX_ENV=prod

RUN apt-get update -y && apt-get install -y build-essential git && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

FROM debian:${RUNTIME_DEBIAN_VERSION} AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 \
    PHX_SERVER=true \
    PORT=4040

WORKDIR /app

RUN useradd --create-home --uid 1000 app && chown app:app /app
USER app

COPY --from=builder --chown=app:app /app/_build/prod/rel/offer_service ./

# migrate-then-start entrypoint
RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -e' \
    '/app/bin/offer_service eval "OfferService.Release.migrate"' \
    'exec /app/bin/offer_service start' \
    > /app/bin/server && chmod +x /app/bin/server

EXPOSE 4040
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:4040/health || exit 1

CMD ["/app/bin/server"]
