-- ===========================================================================
-- Voice-driven scheduling. Pipelines (016) already cover recurring *multi-step*
-- routines; these add the light cases so "add a cronjob" is one sentence:
--   schedule_task  - a one-step recurring job (run a tool, or send a message)
--   remind         - a one-off reminder at a time
--   list_schedules / unschedule - see and manage the schedule
-- pg_cron only ever calls a trusted dispatcher (run_scheduled_task / reminder_tick),
-- never model-authored SQL — same invariant as the rest of the system.
-- ===========================================================================

CREATE TABLE scheduled_tasks (
  id         bigserial PRIMARY KEY,
  chat_id    bigint,
  name       text,
  kind       text NOT NULL CHECK (kind IN ('tool','notify')),
  tool       text,
  args       jsonb NOT NULL DEFAULT '{}',
  message    text,
  cron_expr  text NOT NULL,
  enabled    boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE reminders (
  id         bigserial PRIMARY KEY,
  chat_id    bigint,
  due_at     timestamptz NOT NULL,
  message    text NOT NULL,
  sent       boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reminders_due_idx ON reminders (due_at) WHERE NOT sent;

-- The function pg_cron calls for a scheduled task (trusted; reads a row, runs it).
CREATE OR REPLACE FUNCTION run_scheduled_task(p_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE t record;
BEGIN
  SELECT * INTO t FROM scheduled_tasks WHERE id = p_id AND enabled;
  IF NOT FOUND THEN RETURN; END IF;
  IF t.kind = 'tool' THEN
    PERFORM execute_tool(t.tool, t.args, NULL, NULL);
  ELSE
    PERFORM tg_send(t.chat_id, COALESCE(t.message, ''));
  END IF;
END $$;

-- Send any due one-off reminders. (cron: almanac-remind, ~1 min)
CREATE OR REPLACE FUNCTION reminder_tick()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE r record; cnt int := 0;
BEGIN
  FOR r IN SELECT * FROM reminders WHERE NOT sent AND due_at <= now() ORDER BY id LIMIT 50 LOOP
    PERFORM tg_send(r.chat_id, '⏰ ' || r.message);
    UPDATE reminders SET sent = true WHERE id = r.id;
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END $$;

-- Meta-tools ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_schedule_task(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_cron text := btrim(COALESCE(p_args->>'cron', ''));
  v_tool text := p_args->>'tool';
  v_msg  text := p_args->>'message';
  v_chat bigint := NULLIF(cfg('owner_chat_id'), '')::bigint;
  v_kind text; tid bigint;
BEGIN
  IF v_cron = '' THEN RETURN 'ERROR: cron (a 5-field expression) is required'; END IF;
  IF v_tool IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM tool_defs WHERE name = v_tool AND enabled) THEN
      RETURN 'ERROR: unknown tool ' || v_tool;
    END IF;
    v_kind := 'tool';
  ELSIF v_msg IS NOT NULL THEN
    v_kind := 'notify';
  ELSE
    RETURN 'ERROR: provide a tool (+args) to run, or a message to send';
  END IF;
  INSERT INTO scheduled_tasks (chat_id, name, kind, tool, args, message, cron_expr)
  VALUES (v_chat, p_args->>'name', v_kind, v_tool, COALESCE(p_args->'args', '{}'::jsonb), v_msg, v_cron)
  RETURNING id INTO tid;
  PERFORM cron.schedule('task-' || tid, v_cron, 'SELECT run_scheduled_task(' || tid || ')');
  RETURN format('✅ Scheduled task #%s at "%s".', tid, v_cron);
END $$;
SELECT register_tool('schedule_task', $$
{"type":"function","function":{"name":"schedule_task",
 "description":"Schedule a recurring job on a 5-field cron expression (e.g. '0 9 * * 1-5' for 9am on weekdays). Either run a tool (pass tool, plus optional args) or send a recurring reminder message (pass message). For multi-step routines use create_pipeline instead.",
 "parameters":{"type":"object","properties":{
   "cron":{"type":"string","description":"5-field cron expression"},
   "tool":{"type":"string","description":"a tool name to run on the schedule"},
   "args":{"type":"object","description":"arguments for that tool"},
   "message":{"type":"string","description":"a message to send on the schedule (instead of a tool)"},
   "name":{"type":"string","description":"optional label"}},
   "required":["cron"]}}}$$::jsonb, 66);

CREATE OR REPLACE FUNCTION tool_remind(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_msg  text := p_args->>'message';
  v_at   timestamptz := parse_ts(p_args->>'at');
  v_chat bigint := NULLIF(cfg('owner_chat_id'), '')::bigint;
  rid bigint;
BEGIN
  IF v_msg IS NULL OR btrim(v_msg) = '' THEN RETURN 'ERROR: message is required'; END IF;
  IF v_at IS NULL THEN
    RETURN 'ERROR: "at" must be a valid ISO 8601 time (for recurring reminders use schedule_task with a cron expression)';
  END IF;
  INSERT INTO reminders (chat_id, due_at, message) VALUES (v_chat, v_at, v_msg) RETURNING id INTO rid;
  RETURN format('✅ Reminder #%s set for %s.', rid, to_char(v_at, 'YYYY-MM-DD HH24:MI'));
END $$;
SELECT register_tool('remind', $$
{"type":"function","function":{"name":"remind",
 "description":"Set a one-off reminder that messages the user at a specific time. For recurring reminders use schedule_task with a cron expression.",
 "parameters":{"type":"object","properties":{
   "message":{"type":"string"},
   "at":{"type":"string","description":"ISO 8601 date/time to fire"}},
   "required":["message","at"]}}}$$::jsonb, 68);

CREATE OR REPLACE FUNCTION tool_list_schedules(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE jobs text; rems text;
BEGIN
  SELECT string_agg(format('- %s  [%s]', jobname, schedule), E'\n' ORDER BY jobname)
  INTO jobs FROM cron.job WHERE jobname ~ '^(pipeline-|task-|almanac-)';
  SELECT string_agg(format('- reminder #%s at %s: %s', id, to_char(due_at, 'Mon DD HH24:MI'), message),
                    E'\n' ORDER BY due_at)
  INTO rems FROM reminders WHERE NOT sent;
  RETURN 'Scheduled jobs:' || E'\n' || COALESCE(jobs, '(none)')
      || E'\n\nUpcoming reminders:\n' || COALESCE(rems, '(none)');
END $$;
SELECT register_tool('list_schedules', $$
{"type":"function","function":{"name":"list_schedules",
 "description":"List scheduled jobs (pipelines, tasks, and standing jobs) and upcoming one-off reminders.",
 "parameters":{"type":"object","properties":{}}}}$$::jsonb, 65);

CREATE OR REPLACE FUNCTION tool_unschedule(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_name text := btrim(COALESCE(p_args->>'name', '')); tid bigint;
BEGIN
  IF v_name = '' THEN RETURN 'ERROR: name is required (e.g. task-3 or pipeline-demo)'; END IF;
  -- Never let the model remove the core standing jobs (poll/process/kb/...).
  IF v_name !~ '^(pipeline-|task-)' THEN
    RETURN 'ERROR: only pipeline-* or task-* jobs can be removed (core jobs are protected)';
  END IF;
  BEGIN
    PERFORM cron.unschedule(v_name);
  EXCEPTION WHEN others THEN
    RETURN 'No such job: ' || v_name;
  END;
  IF v_name ~ '^task-' THEN
    tid := substring(v_name FROM '^task-(\d+)')::bigint;
    UPDATE scheduled_tasks SET enabled = false WHERE id = tid;
  ELSE
    UPDATE pipelines SET cron_expr = NULL WHERE slug = substring(v_name FROM '^pipeline-(.+)$');
  END IF;
  RETURN '✅ Unscheduled ' || v_name;
END $$;
SELECT register_tool('unschedule', $$
{"type":"function","function":{"name":"unschedule",
 "description":"Remove a scheduled pipeline or task by job name (e.g. 'task-3' or 'pipeline-demo'). Core almanac jobs cannot be removed.",
 "parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}$$::jsonb, 67);
