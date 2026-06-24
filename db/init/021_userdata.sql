-- ===========================================================================
-- Voice-created tables. "Speak to add a table and it makes a migration."
-- This is the one place the system does DDL — but the invariant still holds:
-- the model NEVER emits SQL. It calls these structured tools, and trusted code
-- builds the statement with format('%I') identifier quoting + a type allowlist
-- (no model text is ever concatenated into SQL). AI tables live in their own
-- `userdata` schema, isolated from system/almanac tables, and every DDL is
-- recorded in schema_migrations. create_table auto-applies; add_column and
-- drop_table require an explicit confirm.
-- ===========================================================================

CREATE SCHEMA IF NOT EXISTS userdata;

CREATE TABLE schema_migrations (
  id         bigserial PRIMARY KEY,
  name       text NOT NULL,
  ddl        text NOT NULL,
  applied_by text NOT NULL DEFAULT 'ai',
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- A safe SQL identifier: lowercase snake_case, <= 63 bytes.
CREATE OR REPLACE FUNCTION ud_ident_ok(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p IS NOT NULL AND p ~ '^[a-z_][a-z0-9_]*$' AND length(p) <= 63
$$;

-- Map a requested column type onto a canonical allowlisted type, else NULL.
CREATE OR REPLACE FUNCTION ud_coltype(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(btrim(COALESCE(p, '')))
    WHEN 'text'        THEN 'text'
    WHEN 'string'      THEN 'text'
    WHEN 'int'         THEN 'bigint'
    WHEN 'integer'     THEN 'bigint'
    WHEN 'bigint'      THEN 'bigint'
    WHEN 'number'      THEN 'numeric'
    WHEN 'numeric'     THEN 'numeric'
    WHEN 'float'       THEN 'numeric'
    WHEN 'decimal'     THEN 'numeric'
    WHEN 'bool'        THEN 'boolean'
    WHEN 'boolean'     THEN 'boolean'
    WHEN 'date'        THEN 'date'
    WHEN 'timestamp'   THEN 'timestamptz'
    WHEN 'timestamptz' THEN 'timestamptz'
    WHEN 'datetime'    THEN 'timestamptz'
    WHEN 'json'        THEN 'jsonb'
    WHEN 'jsonb'       THEN 'jsonb'
    ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION ud_table_exists(p text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'userdata' AND table_name = p)
$$;

-- create_table -------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_create_table(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_name text := lower(btrim(p_args->>'name'));
  col jsonb; cname text; ctype text; coldefs text := ''; ddl text; n int := 0;
BEGIN
  IF NOT ud_ident_ok(v_name) THEN
    RETURN 'ERROR: invalid table name (use lowercase letters, digits and underscores)';
  END IF;
  IF ud_table_exists(v_name) THEN
    RETURN 'A table "' || v_name || '" already exists. Use insert_row, or add_column to extend it.';
  END IF;
  IF jsonb_typeof(p_args->'columns') <> 'array' THEN
    RETURN 'ERROR: columns must be an array of {name, type}';
  END IF;
  FOR col IN SELECT value FROM jsonb_array_elements(p_args->'columns') LOOP
    cname := lower(btrim(col->>'name'));
    IF cname IN ('id', 'created_at') THEN CONTINUE; END IF;   -- added automatically
    IF NOT ud_ident_ok(cname) THEN RETURN 'ERROR: invalid column name: ' || COALESCE(col->>'name', '?'); END IF;
    ctype := ud_coltype(col->>'type');
    IF ctype IS NULL THEN
      RETURN 'ERROR: unsupported type "' || COALESCE(col->>'type', '?') || '" for column ' || cname
        || ' (allowed: text, int, bigint, numeric, boolean, date, timestamptz, jsonb)';
    END IF;
    coldefs := coldefs || format(', %I %s', cname, ctype);
    n := n + 1;
  END LOOP;
  IF n = 0 THEN RETURN 'ERROR: at least one column is required'; END IF;
  ddl := format('CREATE TABLE userdata.%I (id bigserial PRIMARY KEY%s, created_at timestamptz NOT NULL DEFAULT now())',
                v_name, coldefs);
  EXECUTE ddl;
  INSERT INTO schema_migrations (name, ddl) VALUES ('create_table:' || v_name, ddl);
  RETURN format('✅ Created table "%s" with %s column(s). Add data with insert_row.', v_name, n);
END $$;
SELECT register_tool('create_table', $$
{"type":"function","function":{"name":"create_table",
 "description":"Create a new table to track a kind of structured data the user needs (e.g. workouts, expenses, plants). An id and created_at are added automatically. Afterwards use insert_row and query_rows.",
 "parameters":{"type":"object","properties":{
   "name":{"type":"string","description":"table name, lowercase_with_underscores"},
   "columns":{"type":"array","description":"columns as {name, type}; type is one of text, int, bigint, numeric, boolean, date, timestamptz, jsonb",
     "items":{"type":"object","properties":{
       "name":{"type":"string"},"type":{"type":"string"}},"required":["name","type"]}}},
   "required":["name","columns"]}}}$$::jsonb, 80);

-- list_tables ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_list_tables(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE out text;
BEGIN
  SELECT string_agg(line, E'\n' ORDER BY tname) INTO out FROM (
    SELECT c.table_name AS tname,
           format('- %s (%s)', c.table_name,
                  string_agg(c.column_name || ' ' || c.data_type, ', ' ORDER BY c.ordinal_position)
                  FILTER (WHERE c.column_name NOT IN ('id', 'created_at'))) AS line
    FROM information_schema.columns c
    WHERE c.table_schema = 'userdata'
    GROUP BY c.table_name
  ) t;
  RETURN COALESCE(out, 'No custom tables yet. Create one with create_table.');
END $$;
SELECT register_tool('list_tables', $$
{"type":"function","function":{"name":"list_tables",
 "description":"List the custom tables you have created and their columns.",
 "parameters":{"type":"object","properties":{}}}}$$::jsonb, 81);

-- insert_row ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_insert_row(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_tbl text := lower(btrim(p_args->>'table'));
  v_data jsonb := p_args->'data';
  collist text; sellist text;
BEGIN
  IF NOT ud_ident_ok(v_tbl) OR NOT ud_table_exists(v_tbl) THEN
    RETURN 'ERROR: no such table "' || COALESCE(p_args->>'table', '?') || '"';
  END IF;
  IF v_data IS NULL OR jsonb_typeof(v_data) <> 'object' THEN
    RETURN 'ERROR: data must be an object of column: value';
  END IF;
  -- Only columns that actually exist; values are bound (jsonb_populate_record),
  -- so nothing from the model reaches SQL as text.
  SELECT string_agg(quote_ident(c.column_name), ', '),
         string_agg('r.' || quote_ident(c.column_name), ', ')
  INTO collist, sellist
  FROM information_schema.columns c
  WHERE c.table_schema = 'userdata' AND c.table_name = v_tbl
    AND c.column_name <> 'id' AND v_data ? c.column_name;
  IF collist IS NULL THEN
    RETURN 'ERROR: none of the given fields match columns of "' || v_tbl || '"';
  END IF;
  EXECUTE format(
    'INSERT INTO userdata.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::userdata.%I, $1) r',
    v_tbl, collist, sellist, v_tbl) USING v_data;
  RETURN '✅ Added a row to ' || v_tbl || '.';
END $$;
SELECT register_tool('insert_row', $$
{"type":"function","function":{"name":"insert_row",
 "description":"Insert a row into one of your custom tables.",
 "parameters":{"type":"object","properties":{
   "table":{"type":"string"},
   "data":{"type":"object","description":"column: value pairs"}},
   "required":["table","data"]}}}$$::jsonb, 82);

-- query_rows ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION tool_query_rows(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_tbl text := lower(btrim(p_args->>'table'));
  v_match jsonb := COALESCE(p_args->'match', '{}'::jsonb);
  v_lim int := LEAST(GREATEST(COALESCE((p_args->>'limit')::int, 20), 1), 100);
  out jsonb;
BEGIN
  IF NOT ud_ident_ok(v_tbl) OR NOT ud_table_exists(v_tbl) THEN
    RETURN 'ERROR: no such table "' || COALESCE(p_args->>'table', '?') || '"';
  END IF;
  -- match is bound as $1 and applied via jsonb containment; only the validated
  -- table identifier is interpolated.
  EXECUTE format(
    'SELECT COALESCE(jsonb_agg(j), ''[]''::jsonb) FROM '
    || '(SELECT to_jsonb(t) j FROM userdata.%I t '
    || ' WHERE ($1 = ''{}''::jsonb OR to_jsonb(t) @> $1) ORDER BY t.id DESC LIMIT %s) s',
    v_tbl, v_lim) INTO out USING v_match;
  IF out = '[]'::jsonb THEN RETURN 'No matching rows in ' || v_tbl || '.'; END IF;
  RETURN jsonb_pretty(out);
END $$;
SELECT register_tool('query_rows', $$
{"type":"function","function":{"name":"query_rows",
 "description":"Read rows from one of your custom tables, optionally filtered by exact column matches.",
 "parameters":{"type":"object","properties":{
   "table":{"type":"string"},
   "match":{"type":"object","description":"optional exact column: value filters"},
   "limit":{"type":"integer"}},
   "required":["table"]}}}$$::jsonb, 83);

-- add_column (ALTER; confirm required) --------------------------------------
CREATE OR REPLACE FUNCTION tool_add_column(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_tbl text := lower(btrim(p_args->>'table'));
  v_col text := lower(btrim(p_args->>'name'));
  v_type text := ud_coltype(p_args->>'type'); ddl text;
BEGIN
  IF (p_args->>'confirm')::boolean IS NOT TRUE THEN
    RETURN 'This will alter table "' || COALESCE(v_tbl, '?') || '". Confirm with the user, then call again with confirm=true.';
  END IF;
  IF NOT ud_ident_ok(v_tbl) OR NOT ud_table_exists(v_tbl) THEN RETURN 'ERROR: no such table'; END IF;
  IF NOT ud_ident_ok(v_col) THEN RETURN 'ERROR: invalid column name'; END IF;
  IF v_type IS NULL THEN RETURN 'ERROR: unsupported type'; END IF;
  ddl := format('ALTER TABLE userdata.%I ADD COLUMN IF NOT EXISTS %I %s', v_tbl, v_col, v_type);
  EXECUTE ddl;
  INSERT INTO schema_migrations (name, ddl) VALUES ('add_column:' || v_tbl || '.' || v_col, ddl);
  RETURN format('✅ Added column %s to %s.', v_col, v_tbl);
END $$;
SELECT register_tool('add_column', $$
{"type":"function","function":{"name":"add_column",
 "description":"Add a column to an existing custom table. Destructive schema change: confirm with the user first, then call with confirm=true.",
 "parameters":{"type":"object","properties":{
   "table":{"type":"string"},"name":{"type":"string"},"type":{"type":"string"},
   "confirm":{"type":"boolean"}},"required":["table","name","type"]}}}$$::jsonb, 84);

-- drop_table (DROP; confirm required) ---------------------------------------
CREATE OR REPLACE FUNCTION tool_drop_table(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_tbl text := lower(btrim(p_args->>'table')); ddl text;
BEGIN
  IF (p_args->>'confirm')::boolean IS NOT TRUE THEN
    RETURN 'This will permanently delete table "' || COALESCE(v_tbl, '?') || '" and all its rows. Confirm with the user, then call again with confirm=true.';
  END IF;
  IF NOT ud_ident_ok(v_tbl) OR NOT ud_table_exists(v_tbl) THEN RETURN 'ERROR: no such table'; END IF;
  ddl := format('DROP TABLE userdata.%I', v_tbl);
  EXECUTE ddl;
  INSERT INTO schema_migrations (name, ddl) VALUES ('drop_table:' || v_tbl, ddl);
  RETURN '✅ Dropped table ' || v_tbl || '.';
END $$;
SELECT register_tool('drop_table', $$
{"type":"function","function":{"name":"drop_table",
 "description":"Permanently delete a custom table and all its rows. Destructive: confirm with the user first, then call with confirm=true.",
 "parameters":{"type":"object","properties":{
   "table":{"type":"string"},"confirm":{"type":"boolean"}},"required":["table"]}}}$$::jsonb, 85);
