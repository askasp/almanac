-- ===========================================================================
-- Knowledge base: pgvector + self-hosted OpenAI-compatible embeddings.
-- Embedding is async (kb_ingest cron) so chat writes stay snappy.
-- ===========================================================================

CREATE OR REPLACE FUNCTION embed_text(p_text text)
RETURNS vector LANGUAGE plpgsql AS $$
DECLARE
  url     text := cfg('embed_base_url') || '/v1/embeddings';
  headers jsonb := jsonb_build_object('Authorization',
                     'Bearer ' || COALESCE(get_secret('embed_api_key'), 'x'));
  body    jsonb := jsonb_build_object('model', cfg('embed_model'), 'input', p_text);
  resp    http_response;
BEGIN
  resp := almanac_http_post(url, body, headers);
  IF resp.status NOT BETWEEN 200 AND 299 THEN
    RAISE EXCEPTION 'embed HTTP % : %', COALESCE(resp.status,0), left(COALESCE(resp.content,''),300);
  END IF;
  RETURN ((resp.content::jsonb)->'data'->0->'embedding')::text::vector;
END $$;

-- Embed notes that don't have a vector yet. Per-row guard: a transient embed
-- failure just leaves the note for the next tick.
CREATE OR REPLACE FUNCTION kb_ingest()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE r record; cnt int := 0; v vector;
BEGIN
  FOR r IN SELECT id, body FROM notes WHERE embedding IS NULL ORDER BY id LIMIT 20 LOOP
    BEGIN
      v := embed_text(r.body);
      UPDATE notes SET embedding = v WHERE id = r.id;
      cnt := cnt + 1;
    EXCEPTION WHEN others THEN
      NULL;  -- retry next tick
    END;
  END LOOP;
  RETURN cnt;
END $$;

CREATE OR REPLACE FUNCTION tool_search_notes(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE q text := p_args->>'query'; lim int := LEAST(COALESCE((p_args->>'limit')::int,5),20);
        qv vector; out text;
BEGIN
  IF q IS NULL OR btrim(q)='' THEN RETURN 'ERROR: query is required'; END IF;
  BEGIN
    qv := embed_text(q);
    SELECT string_agg('- ' || left(body,400), E'\n' ORDER BY d) INTO out
    FROM (SELECT body, embedding <=> qv AS d FROM notes
          WHERE embedding IS NOT NULL ORDER BY d LIMIT lim) s;
  EXCEPTION WHEN others THEN
    out := NULL;  -- embed server down / dim mismatch -> keyword fallback
  END;
  IF out IS NULL THEN
    SELECT string_agg('- ' || left(body,400), E'\n') INTO out
    FROM (SELECT body FROM notes WHERE body ILIKE '%' || q || '%'
          ORDER BY created_at DESC LIMIT lim) s;
  END IF;
  RETURN COALESCE(out, 'No matching notes.');
END $$;
SELECT register_tool('search_notes', $$
{"type":"function","function":{"name":"search_notes",
 "description":"Semantic search over the user's saved notes/facts.",
 "parameters":{"type":"object","properties":{
   "query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}}}$$::jsonb, 41);
