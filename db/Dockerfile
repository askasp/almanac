# Postgres 17 + the four extensions Almanac runs on.
# pgcrypto ships with the official image's contrib; the rest come from PGDG.
FROM postgres:17

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        postgresql-17-cron \
        postgresql-17-http \
        postgresql-17-pgvector \
    && rm -rf /var/lib/apt/lists/*
# ca-certificates provides /etc/ssl/certs/ca-certificates.crt, libcurl's default
# CA bundle. pgsql-http (libcurl) needs it to verify TLS for any https:// call —
# LLM (OpenRouter), Signal, web/browse. It's only a *recommends* of libcurl, so
# --no-install-recommends drops it; without it every https request fails with
# "error setting certificate file: /etc/ssl/certs/ca-certificates.crt".

# Init scripts run once, in filename order, on first cluster init.
# Numeric prefixes enforce: extensions -> schema -> secrets -> config ->
# helpers/functions -> cron schedule -> bootstrap (secrets/config from env).
COPY init/ /docker-entrypoint-initdb.d/
