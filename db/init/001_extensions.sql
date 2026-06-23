-- Almanac extensions. pg_cron is also preloaded via shared_preload_libraries
-- (see docker-compose command) — this just creates its objects.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS http;        -- pgsql-http: outbound HTTP from SQL
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector: knowledge base
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- secrets at rest

-- Almanac code lives in the default schema; this is just a namespace anchor
-- for the GUC used to hold the pgcrypto key (set per-database in bootstrap).
DO $$
BEGIN
  -- Custom GUC placeholder; real value applied by 99_bootstrap.sh via
  -- ALTER DATABASE ... SET almanac.secret_key = '...'.
  PERFORM set_config('almanac.secret_key', '', false);
END $$;
