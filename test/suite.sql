-- Almanac test suite. Runs the real application SQL against real pgcrypto +
-- pgvector, with pgsql-http and pg_cron mocked so LLM/Telegram/web responses
-- are deterministic. No Docker required.
--
--   createdb almanac_test
--   psql -d almanac_test -f test/suite.sql      # prints ALL TESTS PASSED
--
-- (\ir paths are relative to this file, so run it from anywhere.)

\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET almanac.secret_key = 'testkey';

\ir mocks.sql
-- the whole system (skip 001 — real CREATE EXTENSION; mocks cover http/cron)
\ir ../db/init/002_schema.sql
\ir ../db/init/003_secrets.sql
\ir ../db/init/004_config.sql
\ir ../db/init/010_http.sql
\ir ../db/init/011_tools.sql
\ir ../db/init/012_llm.sql
\ir ../db/init/013_telegram.sql
\ir ../db/init/014_worker.sql
\ir ../db/init/015_web.sql
\ir ../db/init/016_pipelines.sql
\ir ../db/init/017_kb.sql
\ir ../db/init/018_gmail.sql
\ir ../db/init/090_cron.sql

SELECT set_cfg('llm_base_url','http://llm');
SELECT set_cfg('embed_base_url','http://embed');
SELECT set_cfg('tg_api_base','http://tg');
SELECT set_cfg('search_base_url','http://search');
SELECT set_cfg('browser_base_url','http://browser');
SELECT set_secret('telegram_token','TESTTOKEN');
SELECT set_secret('llm_api_key','x');
SELECT set_secret('embed_api_key','x');

\echo ''
\echo '== Test A: core tools (record/recall) =='
DO $$
DECLARE r text; n int;
BEGIN
  r := execute_tool('add_todo','{"title":"buy milk","due":"2026-06-25T09:00:00Z"}'::jsonb);
  ASSERT r LIKE '✅%', 'add_todo: '||r;
  SELECT count(*) INTO n FROM todos WHERE title='buy milk'; ASSERT n=1, 'todo not inserted';
  PERFORM execute_tool('record_item_location','{"item":"passports","location":"blue drawer"}'::jsonb);
  r := execute_tool('find_item','{"item":"passport"}'::jsonb);
  ASSERT r ILIKE '%blue drawer%', 'find_item: '||r;
  r := execute_tool('add_event','{"title":"dentist","starts_at":"2026-06-30T15:00:00Z"}'::jsonb);
  ASSERT r LIKE '✅%', 'add_event: '||r;
  r := execute_tool('agenda', jsonb_build_object('date','2026-06-30'));
  ASSERT r ILIKE '%dentist%', 'agenda: '||r;
  r := execute_tool('does_not_exist','{}'::jsonb);
  ASSERT r LIKE 'ERROR: unknown tool%', 'unknown tool: '||r;
  RAISE NOTICE 'Test A passed';
END $$;

\echo '== Test B: LLM tool loop (run_thread) =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('chat/completions','{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"add_todo","arguments":"{\"title\":\"call mom\"}"}}]}}]}'),
 ('chat/completions','{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Done — added \"call mom\"."}}]}');
DO $$
DECLARE tid bigint; mid bigint; r text; n int;
BEGIN
  tid := new_thread('t');
  INSERT INTO messages(thread_id,role,content,status,tg_chat_id,tg_message_id)
  VALUES (tid,'user','remind me to call mom','pending',5,100) RETURNING id INTO mid;
  r := run_thread(tid, mid);
  ASSERT r ILIKE '%call mom%', 'run_thread final: '||r;
  SELECT count(*) INTO n FROM todos WHERE title='call mom';
  ASSERT n=1, 'tool call inside loop did not insert todo';
  UPDATE messages SET status='done' WHERE id=mid;
  RAISE NOTICE 'Test B passed';
END $$;

\echo '== Test C: full inbound -> reply (process_pending) =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('chat/completions','{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hi there!"}}]}'),
 ('sendMessage','{"ok":true,"result":{"message_id":999}}');
DO $$
DECLARE tid bigint; mid bigint; n int; rep text;
BEGIN
  tid := new_thread('c');
  INSERT INTO messages(thread_id,role,content,status,tg_chat_id,tg_message_id)
  VALUES (tid,'user','hello','pending',5,200) RETURNING id INTO mid;
  PERFORM process_pending();
  SELECT status INTO rep FROM messages WHERE id=mid; ASSERT rep='done', 'user msg status: '||rep;
  SELECT content INTO rep FROM messages WHERE thread_id=tid AND role='assistant' ORDER BY id DESC LIMIT 1;
  ASSERT rep ILIKE '%hi there%', 'assistant reply: '||COALESCE(rep,'(null)');
  SELECT count(*) INTO n FROM http_mock_queue WHERE seen_uri ILIKE '%sendMessage%';
  ASSERT n>=1, 'tg_send not called';
  RAISE NOTICE 'Test C passed';
END $$;

\echo '== Test C2: command routing (ls) =='
INSERT INTO http_mock_queue(match,body) VALUES ('sendMessage','{"ok":true,"result":{"message_id":1000}}');
DO $$
DECLARE tid bigint; mid bigint; rep text;
BEGIN
  tid := new_thread('lscmd');
  INSERT INTO messages(thread_id,role,content,status,tg_chat_id,tg_message_id)
  VALUES (tid,'user','ls','pending',5,300) RETURNING id INTO mid;
  PERFORM process_pending();
  SELECT content INTO rep FROM messages WHERE thread_id=tid AND role='assistant' ORDER BY id DESC LIMIT 1;
  ASSERT rep ILIKE '%Recent threads%', 'ls reply: '||COALESCE(rep,'(null)');
  RAISE NOTICE 'Test C2 passed';
END $$;

\echo '== Test D: inbound polling + thread resolution (tg_poll) =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('getUpdates','{"ok":true,"result":[{"update_id":10,"message":{"message_id":400,"chat":{"id":5},"text":"hello from poll"}}]}');
DO $$
DECLARE n int; lu bigint;
BEGIN
  PERFORM tg_poll();
  SELECT count(*) INTO n FROM messages WHERE content='hello from poll' AND status='pending';
  ASSERT n=1, 'tg_poll did not ingest the message';
  SELECT last_update_id INTO lu FROM tg_state; ASSERT lu=10, 'offset not advanced: '||lu;
  RAISE NOTICE 'Test D passed';
END $$;

\echo '== Test E: pipelines (author + run, tool/ai/notify) =='
SELECT tool_create_pipeline('{"name":"Demo","slug":"demo"}'::jsonb, NULL, NULL);
SELECT tool_add_pipeline_step('{"slug":"demo","kind":"tool","tool":"add_note","args":{"body":"pipeline note"}}'::jsonb, NULL, NULL);
SELECT tool_add_pipeline_step('{"slug":"demo","kind":"ai","prompt":"summarize: {{step_1}}"}'::jsonb, NULL, NULL);
SELECT tool_add_pipeline_step('{"slug":"demo","kind":"notify","message":"done: {{step_2}}"}'::jsonb, NULL, NULL);
INSERT INTO http_mock_queue(match,body) VALUES
 ('chat/completions','{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"a short summary"}}]}'),
 ('sendMessage','{"ok":true,"result":{"message_id":1500}}');
SELECT set_cfg('owner_chat_id','5');
DO $$
DECLARE pid bigint; r text; n int;
BEGIN
  SELECT id INTO pid FROM pipelines WHERE slug='demo';
  r := run_pipeline(pid,'manual');
  ASSERT r ILIKE '%notified%', 'run_pipeline result: '||r;
  SELECT count(*) INTO n FROM notes WHERE body='pipeline note'; ASSERT n=1, 'tool step did not run';
  SELECT count(*) INTO n FROM pipeline_run_steps prs JOIN pipeline_runs pr ON pr.id=prs.run_id
   WHERE pr.pipeline_id=pid AND prs.status='done'; ASSERT n=3, 'expected 3 done steps, got '||n;
  SELECT status INTO r FROM pipeline_runs WHERE pipeline_id=pid ORDER BY id DESC LIMIT 1;
  ASSERT r='done', 'run status: '||r;
  RAISE NOTICE 'Test E passed';
END $$;

\echo '== Test F: knowledge base (embed + search) =='
INSERT INTO http_mock_queue(match, body)
SELECT 'embeddings',
  json_build_object('data', json_build_array(json_build_object('embedding',
    (SELECT json_agg(CASE WHEN g=1 THEN 1 ELSE 0 END) FROM generate_series(1,1024) g))))::text
FROM generate_series(1,2);
DO $$
DECLARE n int; r text;
BEGIN
  INSERT INTO notes(body) VALUES ('the wifi password is hunter2');
  PERFORM kb_ingest();
  SELECT count(*) INTO n FROM notes WHERE body LIKE 'the wifi%' AND embedding IS NOT NULL;
  ASSERT n=1, 'kb_ingest did not embed the note';
  r := execute_tool('search_notes','{"query":"wifi"}'::jsonb);
  ASSERT r ILIKE '%hunter2%', 'search_notes: '||r;
  RAISE NOTICE 'Test F passed';
END $$;

\echo '== Test G: schedule a pipeline (cron) =='
DO $$
DECLARE n int;
BEGIN
  PERFORM execute_tool('schedule_pipeline','{"slug":"demo","cron":"0 8 * * *"}'::jsonb);
  SELECT count(*) INTO n FROM cron.job WHERE jobname='pipeline-demo'; ASSERT n=1, 'pipeline not scheduled';
  RAISE NOTICE 'Test G passed';
END $$;

\echo '== Test H: web + browser tools + SSRF guard =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('search','{"results":[{"title":"Oslo weather","url":"http://x","content":"sunny 20C"}]}'),
 ('browser','{"title":"Example","text":"hello world"}');
DO $$
DECLARE r text;
BEGIN
  r := execute_tool('web_search','{"query":"oslo weather"}'::jsonb);
  ASSERT r ILIKE '%Oslo weather%', 'web_search: '||r;
  r := execute_tool('browse','{"url":"https://example.com"}'::jsonb);
  ASSERT r ILIKE '%hello world%', 'browse: '||r;
  r := execute_tool('browse','{"url":"http://localhost:9000/admin"}'::jsonb);
  ASSERT r LIKE 'ERROR:%', 'SSRF guard did not block localhost: '||r;
  RAISE NOTICE 'Test H passed';
END $$;

\echo '== Test I: standing cron jobs registered =='
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM cron.job WHERE jobname IN
    ('almanac-poll','almanac-process','almanac-kb','almanac-daily','almanac-cleanup');
  ASSERT n=5, 'expected 5 standing jobs, got '||n;
  RAISE NOTICE 'Test I passed';
END $$;

\echo ''
\echo '================  ALL TESTS PASSED  ================'
