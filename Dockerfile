# The manifest registry: the Phoenix app plus the signed catalog it imports at boot.
#
#   docker build --build-arg CATALOG_COMMIT=$(git rev-parse HEAD) \
#     -t harbor.home/library/ragentic-manifests:$(git rev-parse --short HEAD) .
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261020-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

# Only what the server reads: the signed indexes and bundles, plus each app's
# MANIFEST.md front matter for labels. The pretty-printed manifest.json sources
# are excluded by .dockerignore.
COPY catalog /catalog-src
RUN mkdir /catalog \
  && cd /catalog-src \
  && cp -r --parents index.json browse-index.json categories.json registry.json bundles browse-bundles /catalog \
  && find apps -name MANIFEST.md -exec cp --parents {} /catalog \;

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ARG CATALOG_COMMIT=""
ENV MIX_ENV="prod" \
    PHX_SERVER="true" \
    MANIFESTS_CATALOG_DIR="/app/catalog" \
    MANIFESTS_CATALOG_COMMIT="${CATALOG_COMMIT}"

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/manifests ./
COPY --from=builder --chown=nobody:root /catalog ./catalog

USER nobody

CMD ["/app/bin/manifests", "start"]
