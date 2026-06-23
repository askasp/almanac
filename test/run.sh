#!/usr/bin/env bash
# Run Almanac's SQL test suite against a throwaway database.
# Requires: a local PostgreSQL you can create databases on, with pgvector
# installed (apt: postgresql-<ver>-pgvector). pgsql-http and pg_cron are mocked.
#
#   ./test/run.sh
#
# Honors standard libpq env vars (PGHOST/PGUSER/PGPORT/...). Override the temp
# db name with ALMANAC_TEST_DB.
set -euo pipefail

DB="${ALMANAC_TEST_DB:-almanac_test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "→ creating throwaway database '$DB'"
dropdb --if-exists --force "$DB" >/dev/null 2>&1 || true
createdb "$DB"
trap 'dropdb --if-exists --force "$DB" >/dev/null 2>&1 || true' EXIT

psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HERE/suite.sql"
