-- Test doubles for the extensions we can't install here (pgsql-http, pg_cron).
-- pgcrypto + vector are REAL. This lets us exercise all the plpgsql logic and
-- script deterministic LLM / Telegram / web responses.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

-- ---- mock pgsql-http ----
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='http_header') THEN
    CREATE TYPE http_header AS (field varchar, value varchar);
  END IF;
END $$;
-- pgsql-http exposes a constructor function with the same name as the type
CREATE OR REPLACE FUNCTION http_header(field varchar, value varchar)
RETURNS http_header LANGUAGE sql IMMUTABLE AS $$ SELECT ROW(field, value)::http_header $$;
DROP TYPE IF EXISTS http_request CASCADE;
DROP TYPE IF EXISTS http_response CASCADE;
CREATE TYPE http_request  AS (method varchar, uri varchar, headers http_header[], content_type varchar, content varchar);
CREATE TYPE http_response AS (status integer, content_type varchar, headers http_header[], content varchar);

CREATE OR REPLACE FUNCTION http_set_curlopt(curlopt varchar, value varchar)
RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;

CREATE TABLE IF NOT EXISTS http_mock_queue (
  id serial PRIMARY KEY, match text, status int DEFAULT 200, body text DEFAULT '{}',
  consumed boolean DEFAULT false, seen_uri text, seen_body text, created_at timestamptz DEFAULT now()
);

-- Pops the lowest-id unconsumed rule whose `match` is a substring of the URI.
CREATE OR REPLACE FUNCTION http(req http_request)
RETURNS http_response LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM http_mock_queue
   WHERE NOT consumed AND match <> '(unmatched)' AND req.uri ILIKE '%'||match||'%'
   ORDER BY id LIMIT 1;
  IF FOUND THEN
    UPDATE http_mock_queue SET consumed=true, seen_uri=req.uri, seen_body=req.content WHERE id=r.id;
    RETURN (r.status, 'application/json', NULL::http_header[], r.body)::http_response;
  END IF;
  INSERT INTO http_mock_queue(match, consumed, seen_uri, seen_body)
  VALUES ('(unmatched)', true, req.uri, req.content);
  RETURN (200, 'application/json', NULL::http_header[], '{}')::http_response;
END $$;

-- ---- mock pg_cron ----
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE IF NOT EXISTS cron.job (
  jobid serial PRIMARY KEY, jobname text, schedule text, command text, active boolean DEFAULT true);
CREATE TABLE IF NOT EXISTS cron.job_run_details (
  jobid bigint, runid serial, status text, return_message text,
  start_time timestamptz DEFAULT now(), end_time timestamptz DEFAULT now(), command text);
CREATE OR REPLACE FUNCTION cron.schedule(job_name text, schedule text, command text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE id bigint;
BEGIN
  DELETE FROM cron.job WHERE jobname=job_name;
  INSERT INTO cron.job(jobname, schedule, command) VALUES (job_name, schedule, command) RETURNING jobid INTO id;
  RETURN id;
END $$;
CREATE OR REPLACE FUNCTION cron.unschedule(job_name text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN DELETE FROM cron.job WHERE jobname=job_name; RETURN true; END $$;
