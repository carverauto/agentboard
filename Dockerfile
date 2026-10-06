# syntax=docker/dockerfile:1
#
# Dashboard/API image for agentboard (Phoenix release).
#
# This mirrors the Bazel-built image (//build/release:dashboard): Elixir 1.19.4,
# OTP 28.1, esbuild 0.25.4, an Ubuntu Noble runtime, UID/GID 10001, the release
# under /app and release state under /tmp. Use it when you want to run
# agentboard without the project's remote Bazel setup:
#
#   docker build -t agentboard-dashboard .
#
# Docker Compose (docker-compose.yml) builds this file for you.

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.4-erlang-28.1-ubuntu-noble-20260509.1
ARG RUNTIME_IMAGE=ubuntu:noble

FROM ${ELIXIR_IMAGE} AS build
ARG ESBUILD_VERSION=0.25.4
ARG TARGETARCH
ENV MIX_ENV=prod LANG=C.UTF-8
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) pkg=linux-x64 ;; \
      arm64) pkg=linux-arm64 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://registry.npmjs.org/@esbuild/${pkg}/-/${pkg}-${ESBUILD_VERSION}.tgz" \
      | tar -xz -C /usr/local --strip-components=1 package/bin/esbuild; \
    esbuild --version
RUN mix local.hex --force && mix local.rebar --force
WORKDIR /src/web

# Dependencies first so source edits reuse the cached layer.
COPY web/mix.exs web/mix.lock ./
COPY web/config/config.exs web/config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY web/lib lib
COPY web/priv priv
COPY web/assets assets
COPY web/config/runtime.exs config/
RUN esbuild assets/app.js --bundle --minify --outdir=priv/static/assets \
      --alias:phoenix="$PWD/deps/phoenix/priv/static/phoenix.mjs" \
      --alias:phoenix_html="$PWD/deps/phoenix_html/priv/static/phoenix_html.js" \
      --alias:phoenix_live_view="$PWD/deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js" \
 && mix compile \
 && mix release --overwrite

FROM ${RUNTIME_IMAGE} AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3t64 libncurses6 libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 agentboard \
 && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin agentboard
WORKDIR /app
COPY --from=build --chown=0:0 /src/web/_build/prod/rel/agentboard /app
ENV PHX_SERVER=true \
    PORT=4000 \
    RELEASE_TMP=/tmp/agentboard \
    RELEASE_DISTRIBUTION=none \
    HOME=/tmp \
    LANG=C.UTF-8 \
    ELIXIR_ERL_OPTIONS=+fnu
COPY LICENSE /usr/share/doc/agentboard/LICENSE
USER 10001:10001
EXPOSE 4000
LABEL org.opencontainers.image.title="agentboard" \
      org.opencontainers.image.source="https://github.com/carverauto/agentboard" \
      org.opencontainers.image.description="agentboard dashboard and API (Phoenix release)" \
      org.opencontainers.image.licenses="Apache-2.0"
ENTRYPOINT ["/app/bin/agentboard"]
CMD ["start"]
