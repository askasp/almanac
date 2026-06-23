-- ===========================================================================
-- Thin wrappers over pgsql-http so the rest of the code can do JSON HTTP with
-- custom headers (Authorization, etc.) and a configurable timeout. These are
-- SYNCHRONOUS/blocking — only ever call them from the pg_cron workers, never a
-- trigger.
-- ===========================================================================

CREATE OR REPLACE FUNCTION almanac_http_headers(p_headers jsonb)
RETURNS http_header[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    (SELECT array_agg(http_header(key, value)) FROM jsonb_each_text(p_headers)),
    ARRAY[]::http_header[]
  )
$$;

CREATE OR REPLACE FUNCTION almanac_http_post(
  p_url text, p_body jsonb, p_headers jsonb DEFAULT '{}'::jsonb
) RETURNS http_response
LANGUAGE plpgsql AS $$
DECLARE resp http_response;
BEGIN
  PERFORM http_set_curlopt('CURLOPT_TIMEOUT', cfg('http_timeout', '120'));
  PERFORM http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '10');
  SELECT * INTO resp FROM http((
    'POST', p_url, almanac_http_headers(p_headers), 'application/json', p_body::text
  )::http_request);
  RETURN resp;
END $$;

CREATE OR REPLACE FUNCTION almanac_http_get(
  p_url text, p_headers jsonb DEFAULT '{}'::jsonb
) RETURNS http_response
LANGUAGE plpgsql AS $$
DECLARE resp http_response;
BEGIN
  PERFORM http_set_curlopt('CURLOPT_TIMEOUT', cfg('http_timeout', '120'));
  PERFORM http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '10');
  SELECT * INTO resp FROM http((
    'GET', p_url, almanac_http_headers(p_headers), NULL, NULL
  )::http_request);
  RETURN resp;
END $$;

-- Form-encoded POST (Google OAuth token endpoint).
CREATE OR REPLACE FUNCTION almanac_http_post_form(
  p_url text, p_form text, p_headers jsonb DEFAULT '{}'::jsonb
) RETURNS http_response
LANGUAGE plpgsql AS $$
DECLARE resp http_response;
BEGIN
  PERFORM http_set_curlopt('CURLOPT_TIMEOUT', cfg('http_timeout', '120'));
  SELECT * INTO resp FROM http((
    'POST', p_url, almanac_http_headers(p_headers),
    'application/x-www-form-urlencoded', p_form
  )::http_request);
  RETURN resp;
END $$;
