-- ===========================================================================
-- Client-side web tools (OpenAI/vLLM has no server-side web tools).
--   web_fetch  : simple http_get + HTML->text   (SSRF-guarded)
--   web_search : SearXNG JSON API
--   browse     : Playwright sidecar (JS pages, logins, clicks)
-- ===========================================================================

CREATE OR REPLACE FUNCTION url_host(p_url text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(substring(p_url FROM '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+)'))
$$;

-- Best-effort SSRF guard. URLs come from untrusted model output that fetched
-- web/email content can prompt-inject. Blocks loopback/private/link-local and
-- our own compose service names. (Not DNS-rebinding-proof; the sidecar should
-- also restrict egress in hardened deployments.)
CREATE OR REPLACE FUNCTION is_safe_public_url(p_url text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE h text := url_host(p_url);
BEGIN
  IF p_url !~* '^https?://' OR h IS NULL THEN RETURN false; END IF;
  IF h IN ('localhost','db','browser','searxng','opencode','host.docker.internal') THEN RETURN false; END IF;
  IF h ~ '^(127\.|10\.|0\.|169\.254\.|192\.168\.|::1$)' THEN RETURN false; END IF;
  IF h ~ '^172\.(1[6-9]|2[0-9]|3[0-1])\.' THEN RETURN false; END IF;
  IF h ~ '\.(local|internal)$' THEN RETURN false; END IF;
  RETURN true;
END $$;

-- RFC-3986 percent-encoding, byte-correct for UTF-8.
CREATE OR REPLACE FUNCTION urlencode(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(
    CASE WHEN b BETWEEN 48 AND 57 OR b BETWEEN 65 AND 90 OR b BETWEEN 97 AND 122
              OR b IN (45,46,95,126) THEN chr(b)
         ELSE '%' || lpad(upper(to_hex(b)), 2, '0') END, ''), '')
  FROM (SELECT get_byte(convert_to(p,'UTF8'), gs) AS b
        FROM generate_series(0, length(convert_to(p,'UTF8'))-1) gs) s
$$;

-- web_fetch -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_web_fetch(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE u text := p_args->>'url'; resp http_response; t text;
BEGIN
  IF u IS NULL THEN RETURN 'ERROR: url is required'; END IF;
  IF NOT is_safe_public_url(u) THEN RETURN 'ERROR: refused to fetch a non-public/blocked URL'; END IF;
  resp := almanac_http_get(u);
  IF resp.status NOT BETWEEN 200 AND 299 THEN
    RETURN 'ERROR: fetch HTTP ' || COALESCE(resp.status,0);
  END IF;
  t := COALESCE(resp.content, '');
  t := regexp_replace(t, '<(script|style)[^>]*>.*?</\1>', ' ', 'gis');
  t := regexp_replace(t, '<[^>]+>', ' ', 'g');
  t := regexp_replace(t, '&nbsp;', ' ', 'g');
  t := regexp_replace(t, '\s+', ' ', 'g');
  RETURN left(btrim(t), 6000);
END $$;
SELECT register_tool('web_fetch', $$
{"type":"function","function":{"name":"web_fetch",
 "description":"Fetch a simple (non-JS) web page and return its text.",
 "parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}}$$::jsonb, 50);

-- web_search ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_web_search(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE q text := p_args->>'query'; lim int := LEAST(COALESCE((p_args->>'limit')::int,5),10);
        resp http_response; out text;
BEGIN
  IF q IS NULL OR btrim(q)='' THEN RETURN 'ERROR: query is required'; END IF;
  resp := almanac_http_get(cfg('search_base_url') || '/search?format=json&q=' || urlencode(q));
  IF resp.status NOT BETWEEN 200 AND 299 THEN
    RETURN 'ERROR: search HTTP ' || COALESCE(resp.status,0);
  END IF;
  SELECT string_agg(format('%s%s%s',
            COALESCE(r->>'title','(no title)'),
            COALESCE(E'\n  ' || (r->>'url'), ''),
            COALESCE(E'\n  ' || left(r->>'content', 300), '')),
            E'\n\n')
  INTO out
  FROM (SELECT value AS r FROM jsonb_array_elements(((resp.content::jsonb)->'results'))
        LIMIT lim) s;
  RETURN COALESCE(out, 'No results.');
END $$;
SELECT register_tool('web_search', $$
{"type":"function","function":{"name":"web_search",
 "description":"Search the web and return the top results (title, url, snippet).",
 "parameters":{"type":"object","properties":{
   "query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}}}$$::jsonb, 51);

-- browse (Playwright sidecar) ----------------------------------------------
CREATE OR REPLACE FUNCTION tool_browse(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE u text := p_args->>'url'; resp http_response; body jsonb; r jsonb;
BEGIN
  IF u IS NULL THEN RETURN 'ERROR: url is required'; END IF;
  IF NOT is_safe_public_url(u) THEN RETURN 'ERROR: refused to browse a non-public/blocked URL'; END IF;
  body := p_args;                          -- pass url + optional actions/extract through
  resp := almanac_http_post(cfg('browser_base_url') || '/browse', body);
  IF resp.status NOT BETWEEN 200 AND 299 THEN
    RETURN 'ERROR: browser HTTP ' || COALESCE(resp.status,0) || ' ' || left(COALESCE(resp.content,''),300);
  END IF;
  r := resp.content::jsonb;
  IF r ? 'error' THEN RETURN 'ERROR: ' || (r->>'error'); END IF;
  RETURN left(COALESCE(r->>'title','') || E'\n' || COALESCE(r->>'text',''), 8000);
END $$;
SELECT register_tool('browse', $$
{"type":"function","function":{"name":"browse",
 "description":"Open a page in a real headless browser (JavaScript, logins, clicks) and return its rendered text. Use for SPAs like flight/booking sites that web_fetch can't read.",
 "parameters":{"type":"object","properties":{
   "url":{"type":"string"},
   "actions":{"type":"array","description":"Optional steps: [{\"type\":\"click|fill|wait\",\"selector\":\"...\",\"value\":\"...\"}]",
              "items":{"type":"object"}},
   "extract":{"type":"string","description":"Optional CSS selector to extract instead of full text"}},
   "required":["url"]}}}$$::jsonb, 52);
