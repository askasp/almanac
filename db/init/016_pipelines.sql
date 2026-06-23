-- ===========================================================================
-- Pipelines: AI- or human-authored multi-step routines stored as plain rows,
-- run on demand or on a pg_cron schedule. Steps are tool | ai | notify, and
-- can template prior step outputs via {{step_N}} (or {{steps.N.output}}).
-- The same execute_tool dispatcher backs tool steps.
-- ===========================================================================

CREATE OR REPLACE FUNCTION slugify(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(
           left(regexp_replace(lower(COALESCE(p,'')), '[^a-z0-9]+', '-', 'g'), 40),
           '^-+|-+$', '', 'g')
$$;

-- Plain text substitution (for ai prompts / notify messages).
CREATE OR REPLACE FUNCTION resolve_text(p_text text, p_ctx jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s text := p_text; k text; v text; n text;
BEGIN
  IF s IS NULL THEN RETURN NULL; END IF;
  FOR k, v IN SELECT key, value FROM jsonb_each_text(COALESCE(p_ctx,'{}'::jsonb)) LOOP
    s := replace(s, '{{' || k || '}}', COALESCE(v,''));
    n := substring(k FROM 'step_(\d+)');
    IF n IS NOT NULL THEN s := replace(s, '{{steps.' || n || '.output}}', COALESCE(v,'')); END IF;
  END LOOP;
  RETURN s;
END $$;

-- JSON-safe substitution (for tool args): values are escaped so the result
-- stays valid JSON even when an output contains quotes/newlines.
CREATE OR REPLACE FUNCTION resolve_args(p_args jsonb, p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s text; k text; v text; n text; esc text;
BEGIN
  IF p_args IS NULL THEN RETURN '{}'::jsonb; END IF;
  s := p_args::text;
  FOR k, v IN SELECT key, value FROM jsonb_each_text(COALESCE(p_ctx,'{}'::jsonb)) LOOP
    esc := to_jsonb(COALESCE(v,''))::text;            -- "...escaped..."
    esc := substring(esc FROM 2 FOR length(esc) - 2); -- strip surrounding quotes
    s := replace(s, '{{' || k || '}}', esc);
    n := substring(k FROM 'step_(\d+)');
    IF n IS NOT NULL THEN s := replace(s, '{{steps.' || n || '.output}}', esc); END IF;
  END LOOP;
  RETURN s::jsonb;
EXCEPTION WHEN others THEN RETURN p_args;
END $$;

CREATE OR REPLACE FUNCTION find_pipeline_id(p_args jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE pid bigint;
BEGIN
  IF p_args ? 'id'   THEN RETURN (p_args->>'id')::bigint; END IF;
  IF p_args ? 'slug' THEN SELECT id INTO pid FROM pipelines WHERE slug = p_args->>'slug'; RETURN pid; END IF;
  IF p_args ? 'pipeline' THEN SELECT id INTO pid FROM pipelines WHERE slug = p_args->>'pipeline'; RETURN pid; END IF;
  RETURN NULL;
END $$;

-- An 'ai' step: a focused mini-agent (full tool catalog) that returns a result.
CREATE OR REPLACE FUNCTION run_step_ai(p_prompt text, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  tools jsonb := tool_catalog(); convo jsonb; resp jsonb; msg jsonb; asst jsonb; tc jsonb;
  v_name text; v_args jsonb; v_result text; i int;
BEGIN
  convo := jsonb_build_array(
    jsonb_build_object('role','system','content',
      'You are one step in an automation pipeline. Do exactly what is asked, using tools as needed, and return a concise result. Current time: '
      || to_char(now(),'YYYY-MM-DD HH24:MI')),
    jsonb_build_object('role','user','content', p_prompt));

  FOR i IN 1..GREATEST(cfg('loop_max','6')::int, 1) LOOP
    resp := llm_call(convo, tools);
    msg  := resp->'choices'->0->'message';
    IF msg ? 'tool_calls' AND jsonb_typeof(msg->'tool_calls')='array'
       AND jsonb_array_length(msg->'tool_calls') > 0 THEN
      asst := jsonb_build_object('role','assistant','tool_calls', msg->'tool_calls');
      IF msg->>'content' IS NOT NULL THEN asst := asst || jsonb_build_object('content', msg->'content'); END IF;
      convo := convo || jsonb_build_array(asst);
      FOR tc IN SELECT value FROM jsonb_array_elements(msg->'tool_calls') LOOP
        v_name   := tc->'function'->>'name';
        v_args   := safe_jsonb(tc->'function'->>'arguments');
        v_result := execute_tool(v_name, v_args, p_thread_id, p_run_id);
        convo := convo || jsonb_build_array(jsonb_build_object(
                   'role','tool','tool_call_id', tc->>'id', 'content', v_result));
      END LOOP;
    ELSE
      RETURN COALESCE(msg->>'content', '');
    END IF;
  END LOOP;

  resp := llm_call(convo || jsonb_build_array(jsonb_build_object(
            'role','user','content','Give the final result now; no more tools.')), '[]'::jsonb);
  RETURN COALESCE(resp->'choices'->0->'message'->>'content', '');
END $$;

-- Execute a pipeline end to end. Returns the last step's output (or an error).
CREATE OR REPLACE FUNCTION run_pipeline(
  p_pipeline_id bigint, p_trigger text DEFAULT 'manual', p_init jsonb DEFAULT '{}'
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  run_id bigint; ctx jsonb := COALESCE(p_init,'{}'::jsonb); st record;
  res text; rs_id bigint; last text := ''; v_args jsonb; v_chat bigint; v_msg text;
BEGIN
  IF p_pipeline_id IS NULL THEN RETURN 'ERROR: pipeline not found'; END IF;
  INSERT INTO pipeline_runs (pipeline_id, status, trigger, context)
  VALUES (p_pipeline_id, 'running', p_trigger, ctx) RETURNING id INTO run_id;

  FOR st IN SELECT * FROM pipeline_steps WHERE pipeline_id = p_pipeline_id ORDER BY ordinal LOOP
    INSERT INTO pipeline_run_steps (run_id, step_id, ordinal, status, input)
    VALUES (run_id, st.id, st.ordinal, 'running', st.config) RETURNING id INTO rs_id;
    BEGIN
      IF st.kind = 'tool' THEN
        v_args := resolve_args(st.config->'args', ctx);
        res := execute_tool(st.config->>'tool', v_args, NULL, run_id);
      ELSIF st.kind = 'ai' THEN
        res := run_step_ai(resolve_text(COALESCE(st.config->>'prompt',''), ctx), NULL, run_id);
      ELSIF st.kind = 'notify' THEN
        v_chat := COALESCE((st.config->>'chat_id')::bigint, cfg('owner_chat_id')::bigint);
        v_msg  := resolve_text(COALESCE(st.config->>'message', '{{step_' || (st.ordinal-1) || '}}'), ctx);
        PERFORM tg_send(v_chat, v_msg);
        res := 'notified';
      ELSE
        res := 'ERROR: unknown step kind';
      END IF;

      UPDATE pipeline_run_steps SET status='done', output=to_jsonb(res), finished_at=now() WHERE id=rs_id;
      ctx  := jsonb_set(ctx, ARRAY['step_' || st.ordinal], to_jsonb(res), true);
      last := res;
    EXCEPTION WHEN others THEN
      UPDATE pipeline_run_steps SET status='error', error=left(SQLERRM,1000), finished_at=now() WHERE id=rs_id;
      UPDATE pipeline_runs SET status='error', error=left(SQLERRM,1000), finished_at=now(), context=ctx WHERE id=run_id;
      RETURN 'Pipeline failed at step ' || st.ordinal || ': ' || left(SQLERRM,300);
    END;
  END LOOP;

  UPDATE pipeline_runs SET status='done', finished_at=now(), context=ctx, result=to_jsonb(last) WHERE id=run_id;
  RETURN COALESCE(NULLIF(last,''), 'Pipeline completed.');
END $$;

-- ---------------------------------------------------------------------------
-- Meta-tools: let the model author/run/schedule automations from chat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_create_pipeline(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_name text := p_args->>'name'; v_slug text; pid bigint;
BEGIN
  IF v_name IS NULL THEN RETURN 'ERROR: name is required'; END IF;
  v_slug := COALESCE(NULLIF(slugify(p_args->>'slug'),''), slugify(v_name));
  IF v_slug = '' THEN v_slug := gen_slug(); END IF;
  LOOP
    BEGIN
      INSERT INTO pipelines (slug, name, description, created_by)
      VALUES (v_slug, v_name, p_args->>'description', 'ai') RETURNING id INTO pid;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      v_slug := slugify(v_name) || '-' || gen_slug();
    END;
  END LOOP;
  RETURN '✅ Created pipeline "' || v_name || '" (#' || v_slug ||
         '). Add steps with add_pipeline_step, then run_pipeline or schedule_pipeline.';
END $$;
SELECT register_tool('create_pipeline', $$
{"type":"function","function":{"name":"create_pipeline",
 "description":"Create a new, empty automation pipeline. Then add ordered steps with add_pipeline_step.",
 "parameters":{"type":"object","properties":{
   "name":{"type":"string"},"slug":{"type":"string"},"description":{"type":"string"}},
   "required":["name"]}}}$$::jsonb, 60);

CREATE OR REPLACE FUNCTION tool_add_pipeline_step(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE pid bigint := find_pipeline_id(p_args); v_kind text := p_args->>'kind';
        v_ord int; v_config jsonb;
BEGIN
  IF pid IS NULL THEN RETURN 'ERROR: pipeline not found (pass slug or id)'; END IF;
  IF v_kind NOT IN ('tool','ai','notify') THEN RETURN 'ERROR: kind must be tool, ai, or notify'; END IF;
  v_ord := COALESCE((p_args->>'ordinal')::int,
                    (SELECT COALESCE(max(ordinal),0)+1 FROM pipeline_steps WHERE pipeline_id=pid));
  IF v_kind = 'tool' THEN
    v_config := jsonb_build_object('tool', p_args->>'tool', 'args', COALESCE(p_args->'args','{}'::jsonb));
  ELSIF v_kind = 'ai' THEN
    v_config := jsonb_build_object('prompt', p_args->>'prompt');
  ELSE
    v_config := jsonb_strip_nulls(jsonb_build_object('message', p_args->>'message',
                                                     'chat_id', p_args->>'chat_id'));
  END IF;
  INSERT INTO pipeline_steps (pipeline_id, ordinal, kind, name, config)
  VALUES (pid, v_ord, v_kind, p_args->>'name', v_config)
  ON CONFLICT (pipeline_id, ordinal)
    DO UPDATE SET kind=EXCLUDED.kind, name=EXCLUDED.name, config=EXCLUDED.config;
  RETURN '✅ Step ' || v_ord || ' (' || v_kind || ') added.';
END $$;
SELECT register_tool('add_pipeline_step', $$
{"type":"function","function":{"name":"add_pipeline_step",
 "description":"Append a step to a pipeline. kind=tool runs a tool with args (templated with {{step_N}} from earlier outputs); kind=ai runs a focused sub-agent given a prompt; kind=notify sends a Telegram message (defaults to the previous step's output).",
 "parameters":{"type":"object","properties":{
   "slug":{"type":"string"},"id":{"type":"integer"},
   "kind":{"type":"string","enum":["tool","ai","notify"]},
   "name":{"type":"string"},
   "tool":{"type":"string","description":"tool name for kind=tool"},
   "args":{"type":"object","description":"args for kind=tool; values may use {{step_N}}"},
   "prompt":{"type":"string","description":"prompt for kind=ai"},
   "message":{"type":"string","description":"message for kind=notify"},
   "ordinal":{"type":"integer"}},
   "required":["kind"]}}}$$::jsonb, 61);

CREATE OR REPLACE FUNCTION tool_list_pipelines(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE out text;
BEGIN
  SELECT string_agg(format('#%s  %s — %s step(s)%s', p.slug, p.name, c.n,
            COALESCE(' [cron: ' || p.cron_expr || ']', '')), E'\n' ORDER BY p.created_at)
  INTO out
  FROM pipelines p, LATERAL (SELECT count(*) n FROM pipeline_steps s WHERE s.pipeline_id=p.id) c;
  RETURN COALESCE(out, 'No pipelines yet.');
END $$;
SELECT register_tool('list_pipelines', $$
{"type":"function","function":{"name":"list_pipelines",
 "description":"List existing pipelines with their slug, step count and schedule.",
 "parameters":{"type":"object","properties":{}}}}$$::jsonb, 62);

CREATE OR REPLACE FUNCTION tool_run_pipeline(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE pid bigint := find_pipeline_id(p_args);
BEGIN
  IF pid IS NULL THEN RETURN 'ERROR: pipeline not found'; END IF;
  RETURN run_pipeline(pid, 'chat');
END $$;
SELECT register_tool('run_pipeline', $$
{"type":"function","function":{"name":"run_pipeline",
 "description":"Run a pipeline now, by slug or id.",
 "parameters":{"type":"object","properties":{
   "slug":{"type":"string"},"id":{"type":"integer"}}}}}$$::jsonb, 63);

CREATE OR REPLACE FUNCTION tool_schedule_pipeline(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE pid bigint := find_pipeline_id(p_args); v_cron text := p_args->>'cron';
        v_slug text; jobname text;
BEGIN
  IF pid IS NULL THEN RETURN 'ERROR: pipeline not found'; END IF;
  SELECT slug INTO v_slug FROM pipelines WHERE id = pid;
  jobname := 'pipeline-' || v_slug;
  IF v_cron IS NULL OR btrim(v_cron) = '' THEN
    BEGIN PERFORM cron.unschedule(jobname); EXCEPTION WHEN others THEN END;
    UPDATE pipelines SET cron_expr = NULL WHERE id = pid;
    RETURN 'Unscheduled #' || v_slug;
  END IF;
  PERFORM cron.schedule(jobname, v_cron, format('SELECT run_pipeline(%s, ''cron'')', pid));
  UPDATE pipelines SET cron_expr = v_cron WHERE id = pid;
  RETURN '✅ Scheduled #' || v_slug || ' at "' || v_cron || '"';
END $$;
SELECT register_tool('schedule_pipeline', $$
{"type":"function","function":{"name":"schedule_pipeline",
 "description":"Schedule (or, with an empty cron, unschedule) a pipeline using a 5-field cron expression, e.g. 0 8 * * * for 8am daily.",
 "parameters":{"type":"object","properties":{
   "slug":{"type":"string"},"id":{"type":"integer"},
   "cron":{"type":"string","description":"5-field cron expression; empty to unschedule"}}}}}$$::jsonb, 64);
