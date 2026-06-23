-- ===========================================================================
-- The tool substrate. ONE dispatcher (execute_tool) is shared by the chat loop,
-- pipeline steps, and scheduled jobs. Tools are registered in tool_defs and
-- implemented as functions named tool_<name>(args jsonb, thread_id, run_id).
-- Dispatch is dynamic, so tools defined in later files (web, pipelines, kb)
-- need no forward declaration here.
-- ===========================================================================

CREATE TABLE tool_defs (
  name       text PRIMARY KEY,
  definition jsonb NOT NULL,   -- OpenAI function-tool object
  sort       int NOT NULL DEFAULT 100,
  enabled    boolean NOT NULL DEFAULT true
);

CREATE OR REPLACE FUNCTION register_tool(p_name text, p_def jsonb, p_sort int DEFAULT 100)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO tool_defs (name, definition, sort) VALUES (p_name, p_def, p_sort)
  ON CONFLICT (name) DO UPDATE
    SET definition = EXCLUDED.definition, sort = EXCLUDED.sort, enabled = true
$$;

-- Stable, ordered catalog handed to the model (kept stable for vLLM prefix cache).
CREATE OR REPLACE FUNCTION tool_catalog()
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(definition ORDER BY sort, name), '[]'::jsonb)
  FROM tool_defs WHERE enabled
$$;

-- Safe timestamp parse: NULL on garbage rather than raising.
CREATE OR REPLACE FUNCTION parse_ts(p text)
RETURNS timestamptz LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
  RETURN p::timestamptz;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

-- The dispatcher. The model proposes; this trusted code disposes. No raw SQL
-- tool; args are bound as parameters, never concatenated. A failing tool is
-- rolled back to a savepoint and returned as an error string so the model can
-- self-correct in-loop.
CREATE OR REPLACE FUNCTION execute_tool(
  p_name text, p_args jsonb,
  p_thread_id bigint DEFAULT NULL, p_run_id bigint DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE result text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tool_defs WHERE name = p_name AND enabled) THEN
    result := 'ERROR: unknown tool ' || COALESCE(p_name, '(null)');
  ELSE
    BEGIN
      EXECUTE format('SELECT tool_%I($1,$2,$3)', p_name)
        INTO result USING COALESCE(p_args, '{}'::jsonb), p_thread_id, p_run_id;
    EXCEPTION WHEN others THEN
      result := 'ERROR: ' || SQLERRM;
    END;
  END IF;
  INSERT INTO actions (thread_id, run_id, tool_name, input, result)
  VALUES (p_thread_id, p_run_id, p_name, p_args, result);
  RETURN COALESCE(result, 'ok');
END $$;

-- ---------------------------------------------------------------------------
-- Core SQL-backed tools
-- ---------------------------------------------------------------------------

-- todos ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_add_todo(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_title text := p_args->>'title'; v_due timestamptz := parse_ts(p_args->>'due');
BEGIN
  IF v_title IS NULL OR btrim(v_title) = '' THEN RETURN 'ERROR: title is required'; END IF;
  INSERT INTO todos (title, due, notes, thread_id)
  VALUES (v_title, v_due, p_args->>'notes', p_thread_id);
  RETURN '✅ Added todo: ' || v_title || COALESCE(' (due ' || to_char(v_due, 'YYYY-MM-DD HH24:MI') || ')', '');
END $$;
SELECT register_tool('add_todo', $$
{"type":"function","function":{"name":"add_todo",
 "description":"Add a todo / task to remember to do.",
 "parameters":{"type":"object","properties":{
   "title":{"type":"string","description":"What to do"},
   "due":{"type":"string","description":"Optional ISO 8601 due date/time"},
   "notes":{"type":"string"}},"required":["title"]}}}$$::jsonb, 10);

CREATE OR REPLACE FUNCTION tool_complete_todo(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_id bigint := (p_args->>'id')::bigint; v_title text := p_args->>'title'; r record;
BEGIN
  UPDATE todos SET done = true, done_at = now()
  WHERE NOT done AND (
        (v_id IS NOT NULL AND id = v_id)
     OR (v_id IS NULL AND v_title IS NOT NULL AND title ILIKE '%' || v_title || '%'))
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN 'No matching open todo found.'; END IF;
  RETURN '✅ Completed: ' || r.title;
END $$;
SELECT register_tool('complete_todo', $$
{"type":"function","function":{"name":"complete_todo",
 "description":"Mark a todo done, by id or by a fragment of its title.",
 "parameters":{"type":"object","properties":{
   "id":{"type":"integer"},"title":{"type":"string"}}}}}$$::jsonb, 11);

CREATE OR REPLACE FUNCTION tool_list_todos(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_inc boolean := COALESCE((p_args->>'include_done')::boolean, false);
        v_lim int := LEAST(COALESCE((p_args->>'limit')::int, 20), 100); out text;
BEGIN
  SELECT string_agg(
           format('- [%s] %s%s', CASE WHEN done THEN 'x' ELSE ' ' END, title,
                  COALESCE(' (due ' || to_char(due, 'Mon DD HH24:MI') || ')', '')),
           E'\n' ORDER BY done, due NULLS LAST, id)
  INTO out FROM (
    SELECT * FROM todos WHERE v_inc OR NOT done ORDER BY done, due NULLS LAST, id LIMIT v_lim
  ) t;
  RETURN COALESCE(out, 'No todos.');
END $$;
SELECT register_tool('list_todos', $$
{"type":"function","function":{"name":"list_todos",
 "description":"List todos (open by default).",
 "parameters":{"type":"object","properties":{
   "include_done":{"type":"boolean"},"limit":{"type":"integer"}}}}}$$::jsonb, 12);

-- calendar ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_add_event(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_title text := p_args->>'title'; v_start timestamptz := parse_ts(p_args->>'starts_at');
BEGIN
  IF v_title IS NULL OR btrim(v_title) = '' THEN RETURN 'ERROR: title is required'; END IF;
  IF v_start IS NULL THEN RETURN 'ERROR: starts_at must be a valid ISO 8601 date/time'; END IF;
  INSERT INTO calendar (title, starts_at, ends_at, location, notes, thread_id)
  VALUES (v_title, v_start, parse_ts(p_args->>'ends_at'), p_args->>'location', p_args->>'notes', p_thread_id);
  RETURN '✅ Added event: ' || v_title || ' on ' || to_char(v_start, 'YYYY-MM-DD HH24:MI');
END $$;
SELECT register_tool('add_event', $$
{"type":"function","function":{"name":"add_event",
 "description":"Add a calendar event.",
 "parameters":{"type":"object","properties":{
   "title":{"type":"string"},
   "starts_at":{"type":"string","description":"ISO 8601 start"},
   "ends_at":{"type":"string","description":"ISO 8601 end (optional)"},
   "location":{"type":"string"},"notes":{"type":"string"}},
   "required":["title","starts_at"]}}}$$::jsonb, 20);

CREATE OR REPLACE FUNCTION tool_agenda(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_date date := COALESCE(parse_ts(p_args->>'date')::date, current_date);
        ev text; td text;
BEGIN
  SELECT string_agg(format('- %s  %s%s', to_char(starts_at,'HH24:MI'), title,
                           COALESCE(' @ ' || location, '')), E'\n' ORDER BY starts_at)
  INTO ev FROM calendar WHERE starts_at::date = v_date;
  SELECT string_agg('- ' || title, E'\n' ORDER BY due NULLS LAST)
  INTO td FROM todos WHERE NOT done AND (due IS NULL OR due::date <= v_date);
  RETURN format('Agenda for %s', v_date)
       || E'\n\nEvents:\n'  || COALESCE(ev, '(none)')
       || E'\n\nOpen todos:\n' || COALESCE(td, '(none)');
END $$;
SELECT register_tool('agenda', $$
{"type":"function","function":{"name":"agenda",
 "description":"Show events and due todos for a day (defaults to today).",
 "parameters":{"type":"object","properties":{
   "date":{"type":"string","description":"ISO date, defaults to today"}}}}}$$::jsonb, 21);

-- items: where did I put X --------------------------------------------------
CREATE OR REPLACE FUNCTION tool_record_item_location(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_name text := p_args->>'item'; v_loc text := p_args->>'location'; v_item_id bigint;
BEGIN
  IF v_name IS NULL OR v_loc IS NULL THEN RETURN 'ERROR: item and location are required'; END IF;
  INSERT INTO items (name) VALUES (v_name)
  ON CONFLICT (lower(name)) DO UPDATE SET name = items.name
  RETURNING id INTO v_item_id;
  INSERT INTO item_locations (item_id, location, note) VALUES (v_item_id, v_loc, p_args->>'note');
  RETURN '✅ Noted: ' || v_name || ' is in ' || v_loc;
END $$;
SELECT register_tool('record_item_location', $$
{"type":"function","function":{"name":"record_item_location",
 "description":"Remember where the user put a physical thing.",
 "parameters":{"type":"object","properties":{
   "item":{"type":"string"},"location":{"type":"string"},"note":{"type":"string"}},
   "required":["item","location"]}}}$$::jsonb, 30);

CREATE OR REPLACE FUNCTION tool_find_item(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_name text := p_args->>'item'; r record;
BEGIN
  IF v_name IS NULL THEN RETURN 'ERROR: item is required'; END IF;
  SELECT i.name, l.location, l.noted_at, l.note INTO r
  FROM items i JOIN item_locations l ON l.item_id = i.id
  WHERE i.name ILIKE '%' || v_name || '%'
  ORDER BY l.noted_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN 'No record of where ' || v_name || ' is.'; END IF;
  RETURN r.name || ' is in ' || r.location
       || COALESCE(' (' || r.note || ')', '')
       || ' — noted ' || to_char(r.noted_at, 'Mon DD');
END $$;
SELECT register_tool('find_item', $$
{"type":"function","function":{"name":"find_item",
 "description":"Recall where the user put a physical thing.",
 "parameters":{"type":"object","properties":{"item":{"type":"string"}},"required":["item"]}}}$$::jsonb, 31);

-- notes (free-form facts; KB search lives in 016_kb.sql) --------------------
CREATE OR REPLACE FUNCTION tool_add_note(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_body text := p_args->>'body'; v_tags text[];
BEGIN
  IF v_body IS NULL OR btrim(v_body) = '' THEN RETURN 'ERROR: body is required'; END IF;
  IF p_args ? 'tags' THEN
    SELECT array_agg(value) INTO v_tags FROM jsonb_array_elements_text(p_args->'tags');
  END IF;
  INSERT INTO notes (body, tags, thread_id) VALUES (v_body, v_tags, p_thread_id);
  RETURN '✅ Noted.';
END $$;
SELECT register_tool('add_note', $$
{"type":"function","function":{"name":"add_note",
 "description":"Save a free-form note or fact for later semantic recall.",
 "parameters":{"type":"object","properties":{
   "body":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}}},
   "required":["body"]}}}$$::jsonb, 40);
