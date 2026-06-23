-- ===========================================================================
-- LLM integration against a self-hosted, OpenAI-compatible endpoint (vLLM).
-- llm_call() does one chat/completions request with transient retry.
-- run_thread() drives the function-calling loop for one user turn.
-- ===========================================================================

CREATE OR REPLACE FUNCTION safe_jsonb(p text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p IS NULL OR btrim(p) = '' THEN RETURN '{}'::jsonb; END IF;
  RETURN p::jsonb;
EXCEPTION WHEN others THEN RETURN '{}'::jsonb;
END $$;

-- One chat/completions call. Returns the parsed response JSON. Retries on
-- network errors / 429 / 5xx; raises on 4xx (our bug) or persistent failure.
CREATE OR REPLACE FUNCTION llm_call(p_messages jsonb, p_tools jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  url     text := cfg('llm_base_url') || '/v1/chat/completions';
  headers jsonb := jsonb_build_object('Authorization',
                     'Bearer ' || COALESCE(get_secret('llm_api_key'), 'x'));
  body    jsonb;
  resp    http_response;
  attempt int;
BEGIN
  body := jsonb_build_object(
    'model',       cfg('llm_model'),
    'messages',    p_messages,
    'tool_choice', 'auto',
    'temperature', cfg('temperature','0.3')::numeric,
    'max_tokens',  cfg('max_tokens','1024')::int
  );
  IF p_tools IS NOT NULL AND jsonb_array_length(p_tools) > 0 THEN
    body := body || jsonb_build_object('tools', p_tools);
  END IF;

  FOR attempt IN 1..3 LOOP
    BEGIN
      resp := almanac_http_post(url, body, headers);
    EXCEPTION WHEN others THEN          -- connection error -> retry
      IF attempt >= 3 THEN RAISE; END IF;
      PERFORM pg_sleep(attempt * 2);
      CONTINUE;
    END;

    IF resp.status BETWEEN 200 AND 299 THEN
      RETURN resp.content::jsonb;
    ELSIF (resp.status = 429 OR resp.status >= 500) AND attempt < 3 THEN
      PERFORM pg_sleep(attempt * 2);    -- backoff, then retry
    ELSE
      RAISE EXCEPTION 'LLM HTTP % : %', COALESCE(resp.status, 0),
                      left(COALESCE(resp.content, ''), 500);
    END IF;
  END LOOP;
  RAISE EXCEPTION 'LLM call failed after retries';
END $$;

-- Drive one user turn: build the conversation from thread history, loop the
-- model + tool dispatcher until it returns plain text. Returns the reply text.
CREATE OR REPLACE FUNCTION run_thread(p_thread_id bigint, p_user_msg_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  tools  jsonb := tool_catalog();
  sys    text  := cfg('system_prompt', 'You are a helpful assistant.')
                  || E'\n\nCurrent time: ' || to_char(now(), 'YYYY-MM-DD HH24:MI (Dy)');
  convo  jsonb;
  resp   jsonb; msg jsonb; asst jsonb; tc jsonb;
  v_name text; v_args jsonb; v_result text; v_final text;
  i int;
BEGIN
  -- system + full thread history (done rows) + the new pending user row
  SELECT jsonb_build_array(jsonb_build_object('role','system','content',sys))
         || COALESCE(jsonb_agg(jsonb_build_object('role', role, 'content', content)
                               ORDER BY id), '[]'::jsonb)
  INTO convo
  FROM messages
  WHERE thread_id = p_thread_id
    AND (status = 'done' OR id = p_user_msg_id)
    AND content IS NOT NULL;

  FOR i IN 1..GREATEST(cfg('loop_max','6')::int, 1) LOOP
    resp := llm_call(convo, tools);
    msg  := resp->'choices'->0->'message';

    IF msg ? 'tool_calls'
       AND jsonb_typeof(msg->'tool_calls') = 'array'
       AND jsonb_array_length(msg->'tool_calls') > 0 THEN

      -- replay-safe assistant turn (role/content/tool_calls only)
      asst := jsonb_build_object('role','assistant','tool_calls', msg->'tool_calls');
      IF msg->>'content' IS NOT NULL THEN
        asst := asst || jsonb_build_object('content', msg->'content');
      END IF;
      convo := convo || jsonb_build_array(asst);

      FOR tc IN SELECT value FROM jsonb_array_elements(msg->'tool_calls') LOOP
        v_name   := tc->'function'->>'name';
        v_args   := safe_jsonb(tc->'function'->>'arguments');
        v_result := execute_tool(v_name, v_args, p_thread_id, NULL);
        convo := convo || jsonb_build_array(jsonb_build_object(
                   'role','tool', 'tool_call_id', tc->>'id', 'content', v_result));
      END LOOP;
    ELSE
      RETURN COALESCE(msg->>'content', '(no response)');
    END IF;
  END LOOP;

  -- iteration cap hit: force a final, tool-free answer
  convo := convo || jsonb_build_array(jsonb_build_object(
             'role','user','content','Wrap up now with a final answer; do not call more tools.'));
  resp := llm_call(convo, '[]'::jsonb);
  RETURN COALESCE(resp->'choices'->0->'message'->>'content', '(no response)');
END $$;
