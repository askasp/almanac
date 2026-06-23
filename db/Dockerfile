# Postgres 17 + the four extensions Almanac runs on.
# pgcrypto ships with the official image's contrib; the rest come from PGDG.
FROM postgres:17

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-17-cron \
        postgresql-17-http \
        postgresql-17-pgvector \
    && rm -rf /var/lib/apt/lists/*

# Init scripts run once, in filename order, on first cluster init.
# Numeric prefixes enforce: extensions -> schema -> secrets -> config ->
# helpers/functions -> cron schedule -> bootstrap (secrets/config from env).
COPY init/ /docker-entrypoint-initdb.d/
