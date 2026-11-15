# The hosted image: the front door, Jac's server for the page, the built web
# bundle and the card catalogue, started in hosted mode. Railway builds it
# from the repo root.
#
# The base tag is the version `jac.toml` pins (`jac-version`); a test holds the
# two together, so a Jac upgrade changes both in one pull request.
ARG JAC_VERSION=0.39.2
FROM jaseci/jaclang:${JAC_VERSION}

WORKDIR /app

# The base image's cache directories belong to root, so Jac cannot keep its
# compiled modules there and recompiles the app (over a minute) on every start.
# Keep them under the app, where the build steps fill them for the running container.
ENV JAC_CACHE_HOME=/app/.cache/state \
    XDG_CACHE_HOME=/app/.cache
RUN mkdir -p /app/.cache/state

# Every Jac command needs JAC_DB_URL, or it downloads and starts its own
# Postgres (ADR 0003). The build has no database, so each build step is given
# an address nothing listens on. The running container gets its own from Railway.
ARG BUILD_DB_URL=postgresql://build:build@127.0.0.1:1/none

# Dependencies first, so a code change does not reinstall them. Not --frozen:
# jac.lock also pins the dev dependencies (pytest), so it never matches the
# production set. Every direct dependency in jac.toml is pinned exactly.
COPY --chown=jac:jac jac.toml ./
RUN JAC_DB_URL=$BUILD_DB_URL jac install

# The card catalogue, from MTGJSON and Scryfall. Only its own code and the date
# file are copied first, so it depends on the date file and not on the app's
# source: changing the file always rebuilds it (the weekly rebuild writes
# today's date), and an edit to the app does not re-download the cards.
COPY --chown=jac:jac catalog ./catalog
COPY --chown=jac:jac catalogue_date.txt ./
RUN JAC_DB_URL=$BUILD_DB_URL KP_CACHE=/tmp/kp-cache jac x catalogue && rm -rf /tmp/kp-cache

COPY --chown=jac:jac . .

# The web bundle.
RUN JAC_DB_URL=$BUILD_DB_URL jac build --as client

# Compile the app's modules into the cache now. Started without its settings the
# app compiles, refuses hosted mode and exits, which is all this step wants;
# without it the first start spends over a minute compiling before it can answer
# its health check.
RUN JAC_DB_URL=$BUILD_DB_URL KP_MODE=hosted jac run --no-serve mcp_server.jac 2>&1 | grep -q 'Hosted mode needs these settings'

# Hosted mode: the app refuses to start without its WorkOS settings
# (KP_AUTHKIT_DOMAIN, KP_MCP_URL, WORKOS_CLIENT_ID, WORKOS_API_KEY and
# WORKOS_COOKIE_PASSWORD) and JAC_DB_URL, all set on Railway.
ENV KP_MODE=hosted \
    KP_TRANSPORT=http \
    KP_HTTP_HOST=0.0.0.0 \
    KP_CATALOG=/app/data/catalog.sqlite \
    JAC_STRICT_PERMISSIONS=1

# Railway names the port in PORT.
ENTRYPOINT ["/bin/sh", "-c", "KP_HTTP_PORT=${PORT:-8020} exec jac run --no-serve mcp_server.jac"]
