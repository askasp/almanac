#!/bin/bash
# Runs once on first cluster init (after the .sql files). Pulls the pgcrypto
# key, secrets, and config from the environment into the database. After this,
# the secrets live only in the encrypted `secrets` table.
set -euo pipefail

if [ -z "${ALMANAC_SECRET_KEY:-}" ]; then
  echo "[almanac] ALMANAC_SECRET_KEY is empty — skipping secret/config bootstrap."
  echo "[almanac] Set it and re-init, or load secrets manually via set_secret()."
  exit 0
fi

DB="${POSTGRES_DB:-almanac}"
USER="${POSTGRES_USER:-almanac}"
runsql() { psql -v ON_ERROR_STOP=1 --username "$USER" --dbname "$DB" "$@"; }

# Make the pgcrypto key the database default so every later session (including
# pg_cron workers) can decrypt. Applied at connect time, so the calls below
# (fresh connections) already see it.
runsql -v k="$ALMANAC_SECRET_KEY" \
  -c "ALTER DATABASE \"$DB\" SET almanac.secret_key = :'k';"

set_secret() { [ -n "${2:-}" ] && runsql -v v="$2" -c "SELECT set_secret('$1', :'v');"; }
set_cfg()    { [ -n "${2:-}" ] && runsql -v v="$2" -c "SELECT set_cfg('$1', :'v');"; }

# Secrets (encrypted)
set_secret telegram_token       "${TELEGRAM_TOKEN:-}"
set_secret llm_api_key          "${LLM_API_KEY:-not-needed}"
set_secret embed_api_key        "${EMBED_API_KEY:-not-needed}"
set_secret gmail_client_secret  "${GMAIL_CLIENT_SECRET:-}"

# Config (non-secret) — override the defaults from 004_config.sql with env
set_cfg llm_base_url     "${LLM_BASE_URL:-}"
set_cfg llm_model        "${LLM_MODEL:-}"
set_cfg embed_base_url   "${EMBED_BASE_URL:-}"
set_cfg embed_model      "${EMBED_MODEL:-}"
set_cfg search_base_url  "${SEARCH_BASE_URL:-}"
set_cfg browser_base_url "${BROWSER_BASE_URL:-}"
set_cfg opencode_base_url "${OPENCODE_BASE_URL:-}"
set_cfg gmail_client_id  "${GMAIL_CLIENT_ID:-}"
set_cfg team_mode        "${TEAM_MODE:-}"

echo "[almanac] bootstrap complete."
