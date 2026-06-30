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
\ir ../db/init/019_opencode.sql
\ir ../db/init/020_schedule.sql
\ir ../db/init/021_userdata.sql
\ir ../db/init/022_github.sql
\ir ../db/init/030_team.sql
\ir ../db/init/090_cron.sql

SELECT set_cfg('llm_base_url','http://llm');
SELECT set_cfg('embed_base_url','http://embed');
SELECT set_cfg('tg_api_base','http://tg');
SELECT set_cfg('search_base_url','http://search');
SELECT set_cfg('browser_base_url','http://browser');
SELECT set_cfg('opencode_base_url','http://opencode');
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
    ('almanac-poll','almanac-process','almanac-kb','almanac-code','almanac-remind','almanac-daily','almanac-cleanup');
  ASSERT n=7, 'expected 7 standing jobs, got '||n;
  RAISE NOTICE 'Test I passed';
END $$;

\echo '== Test J: opencode coding sidecar (async + notify) =='
SELECT set_cfg('owner_chat_id','5');
INSERT INTO http_mock_queue(match,body) VALUES
 ('opencode/code','{"job_id":"abc123"}'),
 ('opencode/code/abc123','{"status":"done","result":"Added a healthcheck endpoint","diff":"--- a/app.js\n+++ b/app.js"}'),
 ('sendMessage','{"ok":true,"result":{"message_id":2000}}');
DO $$
DECLARE r text; st text; n int;
BEGIN
  r := execute_tool('code','{"prompt":"add a healthcheck endpoint"}'::jsonb);
  ASSERT r ILIKE '%Started coding job%', 'tool_code: '||r;
  SELECT status INTO st FROM code_jobs ORDER BY id DESC LIMIT 1;
  ASSERT st='running', 'job should be running, got: '||st;
  PERFORM code_poll();
  SELECT status INTO st FROM code_jobs ORDER BY id DESC LIMIT 1;
  ASSERT st='done', 'job should be done after poll, got: '||st;
  SELECT count(*) INTO n FROM http_mock_queue WHERE seen_uri ILIKE '%sendMessage%' AND seen_body ILIKE '%Coding job%';
  ASSERT n>=1, 'requester was not notified of the finished job';
  RAISE NOTICE 'Test J passed';
END $$;

\echo '== Test K: voice scheduling (task, reminder, list, unschedule) =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('sendMessage','{"ok":true,"result":{"message_id":2100}}');
DO $$
DECLARE r text; n int; tid bigint;
BEGIN
  r := execute_tool('schedule_task','{"cron":"0 9 * * 1-5","tool":"add_note","args":{"body":"standup"}}'::jsonb);
  ASSERT r ILIKE '%Scheduled task%', 'schedule_task: '||r;
  SELECT id INTO tid FROM scheduled_tasks ORDER BY id DESC LIMIT 1;
  SELECT count(*) INTO n FROM cron.job WHERE jobname='task-'||tid; ASSERT n=1, 'task cron not registered';
  PERFORM run_scheduled_task(tid);
  SELECT count(*) INTO n FROM notes WHERE body='standup'; ASSERT n=1, 'scheduled tool did not run';
  PERFORM execute_tool('remind', jsonb_build_object('message','call the bank',
                       'at', to_char(now()-interval '1 minute','YYYY-MM-DD"T"HH24:MI:SSOF')));
  PERFORM reminder_tick();
  SELECT count(*) INTO n FROM reminders WHERE message='call the bank' AND sent; ASSERT n=1, 'reminder not sent';
  r := execute_tool('list_schedules','{}'::jsonb);
  ASSERT r ILIKE '%task-'||tid||'%', 'list_schedules missing task: '||r;
  r := execute_tool('unschedule', jsonb_build_object('name','task-'||tid));
  ASSERT r ILIKE '%Unscheduled%', 'unschedule: '||r;
  SELECT count(*) INTO n FROM cron.job WHERE jobname='task-'||tid; ASSERT n=0, 'task not unscheduled';
  RAISE NOTICE 'Test K passed';
END $$;

\echo '== Test L: voice-created tables (DDL, audited, guarded) =='
DO $$
DECLARE r text; n int;
BEGIN
  r := execute_tool('create_table','{"name":"workouts","columns":[{"name":"kind","type":"text"},{"name":"distance_km","type":"numeric"},{"name":"minutes","type":"int"}]}'::jsonb);
  ASSERT r ILIKE '%Created table%', 'create_table: '||r;
  SELECT count(*) INTO n FROM information_schema.tables WHERE table_schema='userdata' AND table_name='workouts';
  ASSERT n=1, 'userdata.workouts not created';
  SELECT count(*) INTO n FROM schema_migrations WHERE name='create_table:workouts';
  ASSERT n=1, 'migration not recorded';
  r := execute_tool('insert_row','{"table":"workouts","data":{"kind":"run","distance_km":5,"minutes":25}}'::jsonb);
  ASSERT r ILIKE '%Added a row%', 'insert_row: '||r;
  r := execute_tool('query_rows','{"table":"workouts","match":{"kind":"run"}}'::jsonb);
  ASSERT r ILIKE '%run%', 'query_rows content: '||r;
  ASSERT r ILIKE '%25%', 'query_rows minutes: '||r;
  r := execute_tool('list_tables','{}'::jsonb);
  ASSERT r ILIKE '%workouts%', 'list_tables: '||r;
  r := execute_tool('drop_table','{"table":"workouts"}'::jsonb);
  ASSERT r ILIKE '%Confirm%', 'drop without confirm should ask first: '||r;
  SELECT count(*) INTO n FROM information_schema.tables WHERE table_schema='userdata' AND table_name='workouts';
  ASSERT n=1, 'table was dropped without confirm!';
  r := execute_tool('drop_table','{"table":"workouts","confirm":true}'::jsonb);
  ASSERT r ILIKE '%Dropped%', 'drop with confirm: '||r;
  RAISE NOTICE 'Test L passed';
END $$;

\echo '== Test M: team mode (identity, attribution, per-member threads) =='
SELECT set_cfg('team_mode','on');
UPDATE messages SET status='done' WHERE status='pending';  -- drop earlier tests' unprocessed intake (Test D)
INSERT INTO http_mock_queue(match,body) VALUES
 ('getUpdates','{"ok":true,"result":[{"update_id":50,"message":{"message_id":500,"chat":{"id":111},"from":{"id":111,"first_name":"Alice"},"text":"buy printer paper"}},{"update_id":51,"message":{"message_id":501,"chat":{"id":222},"from":{"id":222,"first_name":"Bob"},"text":"book the venue"}}]}'),
 ('chat/completions','{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"t1","type":"function","function":{"name":"add_todo","arguments":"{\"title\":\"buy printer paper\"}"}}]}}]}'),
 ('chat/completions','{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Added."}}]}'),
 ('sendMessage','{"ok":true,"result":{"message_id":600}}'),
 ('chat/completions','{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"t2","type":"function","function":{"name":"add_todo","arguments":"{\"title\":\"book the venue\"}"}}]}}]}'),
 ('chat/completions','{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Added."}}]}'),
 ('sendMessage','{"ok":true,"result":{"message_id":601}}');
DO $$
DECLARE n bigint; aid bigint; bid bigint; r text;
BEGIN
  PERFORM tg_poll();
  SELECT count(*) INTO n FROM members; ASSERT n=2, 'expected 2 members, got '||n;
  SELECT id INTO aid FROM members WHERE tg_user_id=111;
  SELECT id INTO bid FROM members WHERE tg_user_id=222;
  SELECT count(DISTINCT thread_id) INTO n FROM messages WHERE content IN ('buy printer paper','book the venue');
  ASSERT n=2, 'each member should get their own thread, got '||n;
  PERFORM process_pending();
  SELECT member_id INTO n FROM todos WHERE title='buy printer paper'; ASSERT n=aid, 'paper todo not attributed to Alice';
  SELECT member_id INTO n FROM todos WHERE title='book the venue';   ASSERT n=bid, 'venue todo not attributed to Bob';
  r := execute_tool('list_todos','{}'::jsonb);
  ASSERT r ILIKE '%· Alice%', 'list_todos missing Alice attribution: '||r;
  ASSERT r ILIKE '%· Bob%',   'list_todos missing Bob attribution: '||r;
  RAISE NOTICE 'Test M passed';
END $$;

\echo '== Test M2: team daily summary DMs each member =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('sendMessage','{"ok":true,"result":{"message_id":700}}'),
 ('sendMessage','{"ok":true,"result":{"message_id":701}}');
DO $$
DECLARE n bigint;
BEGIN
  PERFORM daily_summary();
  SELECT count(*) INTO n FROM http_mock_queue
   WHERE consumed AND seen_uri ILIKE '%sendMessage%' AND seen_body ILIKE '%Good morning%';
  ASSERT n>=2, 'daily_summary should DM each active member, got '||n;
  RAISE NOTICE 'Test M2 passed';
END $$;
SELECT set_cfg('team_mode','off');   -- restore default

\echo '== Test N: chat allowlist (personal-mode access control) =='
SELECT set_cfg('allowed_chat_ids','5');   -- only user/chat id 5 may use the bot
INSERT INTO http_mock_queue(match,body) VALUES
 ('getUpdates','{"ok":true,"result":[{"update_id":60,"message":{"message_id":800,"chat":{"id":5},"from":{"id":5},"text":"allowed hello"}},{"update_id":61,"message":{"message_id":801,"chat":{"id":999},"from":{"id":999},"text":"stranger hello"}}]}');
DO $$
DECLARE n int; lu bigint;
BEGIN
  PERFORM tg_poll();
  SELECT count(*) INTO n FROM messages WHERE content='allowed hello';
  ASSERT n=1, 'allowlisted sender should be ingested, got '||n;
  SELECT count(*) INTO n FROM messages WHERE content='stranger hello';
  ASSERT n=0, 'non-allowlisted sender must be dropped, got '||n;
  SELECT last_update_id INTO lu FROM tg_state;
  ASSERT lu=61, 'offset must advance past dropped updates too, got '||lu;
  RAISE NOTICE 'Test N passed';
END $$;
SELECT set_cfg('allowed_chat_ids','');   -- restore default (allow all)

\echo '== Test O: self-describing tables (descriptions + describe_table) =='
DO $$
DECLARE r text;
BEGIN
  r := execute_tool('create_table', '{"name":"books","description":"Books I have read","columns":[{"name":"title","type":"text","description":"the book title","required":true},{"name":"rating","type":"int","description":"my rating out of 5"}]}'::jsonb);
  ASSERT r LIKE '✅%', 'create_table with descriptions: '||r;
  -- describe_table surfaces the table + column descriptions and the required flag
  r := execute_tool('describe_table', '{"table":"books"}'::jsonb);
  ASSERT r ILIKE '%Books I have read%', 'table description missing: '||r;
  ASSERT r ILIKE '%the book title%',    'column description missing: '||r;
  ASSERT r ILIKE '%title%(required)%',  'required flag missing: '||r;
  -- list_tables now shows the table description
  r := execute_tool('list_tables', '{}'::jsonb);
  ASSERT r ILIKE '%books%Books I have read%', 'list_tables missing description: '||r;
  -- inserts/queries still work normally
  PERFORM execute_tool('insert_row', '{"table":"books","data":{"title":"Dune","rating":5}}'::jsonb);
  r := execute_tool('query_rows', '{"table":"books","match":{"title":"Dune"}}'::jsonb);
  ASSERT r ILIKE '%Dune%', 'query_rows after describe: '||r;
  RAISE NOTICE 'Test O passed';
END $$;

\echo '== Test P: github commit digest =='
INSERT INTO http_mock_queue(match,body) VALUES
 ('api.github.com', '[{"sha":"abc1234def","commit":{"message":"Fix the parser\n\nlong body here","author":{"name":"Aksel","date":"2026-06-28T10:00:00Z"}},"author":{"login":"askasp"}},{"sha":"99887766aa","commit":{"message":"Add a feature","author":{"name":"Aksel","date":"2026-06-27T09:00:00Z"}},"author":null}]');
DO $$
DECLARE r text;
BEGIN
  r := execute_tool('github_commits', '{"owner":"askasp","repo":"almanac","branch":"main","days":7}'::jsonb);
  ASSERT r ILIKE '%2 commit(s) on main%', 'count/branch: '||r;
  ASSERT r ILIKE '%abc1234%', 'short sha: '||r;
  ASSERT r ILIKE '%Fix the parser%', 'first line: '||r;
  ASSERT r NOT ILIKE '%long body here%', 'should show only the first message line: '||r;
  ASSERT r ILIKE '%askasp%', 'author login: '||r;
  ASSERT r ILIKE '%Aksel%', 'fallback to commit author name when login is null: '||r;
  r := execute_tool('github_commits', '{"repo":"almanac"}'::jsonb);
  ASSERT r LIKE 'ERROR:%', 'missing owner should error: '||r;
  RAISE NOTICE 'Test P passed';
END $$;

\echo ''
\echo '================  ALL TESTS PASSED  ================'
