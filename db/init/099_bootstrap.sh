#!/bin/bash
# Runs once on first cluster init (after the .sql files). Pulls the pgcrypto
# key, secrets, and config from the environment into the database. After this,
# the secrets live only in the encrypted `secrets` table.
#
# IMPORTANT: SQL is fed to psql via stdin (heredocs), NOT `psql -c`. psql only
# performs :'var' / :"var" interpolation when reading from stdin or a file — for
# a -c command string the ":'v'" is sent to the server verbatim and the
# statement dies with `syntax error at or near ":"`. Under ON_ERROR_STOP=1 that
# aborts the whole bootstrap on its first line, silently leaving the DB on the
# 004_config.sql defaults (i.e. .env is never applied). Keep these as heredocs.
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
# (fresh connections) already see it. :"db"/:'k' interpolate via stdin.
runsql -v db="$DB" -v k="$ALMANAC_SECRET_KEY" <<'SQL'
ALTER DATABASE :"db" SET almanac.secret_key = :'k';
SQL

# Store a secret / set a config value only when the env value is non-empty.
# Name and value are bound as psql variables and interpolated via stdin, so
# nothing is string-concatenated into SQL (safe quoting for any characters).
set_secret() {
  [ -n "${2:-}" ] || return 0
  runsql -v n="$1" -v v="$2" <<'SQL'
SELECT set_secret(:'n', :'v');
SQL
}
set_cfg() {
  [ -n "${2:-}" ] || return 0
  runsql -v n="$1" -v v="$2" <<'SQL'
SELECT set_cfg(:'n', :'v');
SQL
}

# Secrets (encrypted)
set_secret telegram_token       "${TELEGRAM_TOKEN:-}"
set_secret llm_api_key          "${LLM_API_KEY:-not-needed}"
set_secret embed_api_key        "${EMBED_API_KEY:-not-needed}"
set_secret gmail_client_secret  "${GMAIL_CLIENT_SECRET:-}"
set_secret github_token         "${GITHUB_TOKEN:-}"

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
set_cfg allowed_chat_ids "${ALLOWED_CHAT_IDS:-}"
set_cfg channel          "${CHANNEL:-}"
set_cfg signal_mode      "${SIGNAL_MODE:-}"
set_cfg signal_number    "${SIGNAL_NUMBER:-}"
set_cfg signal_group_id  "${SIGNAL_GROUP_ID:-}"
set_cfg signal_group_name "${SIGNAL_GROUP_NAME:-}"
set_cfg signal_auto_group "${SIGNAL_AUTO_GROUP:-}"

echo "[almanac] bootstrap complete."
