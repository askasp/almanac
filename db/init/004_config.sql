-- ===========================================================================
-- Default config. Base URLs / models / keys are overwritten from environment
-- by 99_bootstrap.sh on first init; these are fallbacks + tunables.
-- ===========================================================================

SELECT set_cfg('llm_base_url',   'http://host.docker.internal:8000');
SELECT set_cfg('llm_model',      'Qwen/Qwen2.5-7B-Instruct');
SELECT set_cfg('embed_base_url', 'http://host.docker.internal:8001');
SELECT set_cfg('embed_model',    'BAAI/bge-large-en-v1.5');
SELECT set_cfg('search_base_url','http://searxng:8080');
SELECT set_cfg('browser_base_url','http://browser:3000');
SELECT set_cfg('opencode_base_url','http://opencode:5000');

-- Generation tunables
SELECT set_cfg('temperature', '0.3');
SELECT set_cfg('max_tokens',  '1024');
SELECT set_cfg('loop_max',    '6');       -- tool-loop iteration cap
SELECT set_cfg('http_timeout','120');     -- seconds, for pgsql-http calls

-- Worker kill-switches (set to 'off' to pause without unscheduling cron)
SELECT set_cfg('poll_enabled',    'on');
SELECT set_cfg('process_enabled', 'on');

-- Team mode: one instance per context. 'off' = single-user (default). When 'on',
-- members are identified by Telegram user id; data is shared but attributed, and
-- email/credentials stay per-member. See db/init/030_team.sql.
SELECT set_cfg('team_mode', 'off');

-- Access control: comma-separated Telegram user ids (or chat ids) allowed to use
-- this bot. EMPTY = allow anyone who messages it (default). Lock a personal
-- deployment to yourself by setting your Telegram user id (see @userinfobot). In
-- team mode this also gates who may join as a member.
SELECT set_cfg('allowed_chat_ids', '');

-- Single Telegram chat: consecutive messages within this many minutes continue
-- the active thread; reply-to-a-message or "#slug ..." jumps to any thread;
-- a longer gap starts a fresh one. /new forces a fresh thread.
SELECT set_cfg('session_window_minutes', '30');

-- Telegram API base (override for testing against a mock server).
SELECT set_cfg('tg_api_base', 'https://api.telegram.org');

-- The assistant persona. Kept byte-stable so vLLM's prefix cache stays warm;
-- the current time is injected separately at call time.
SELECT set_cfg('system_prompt', $prompt$You are Almanac, a personal assistant the user talks to from Telegram. You file their todos, calendar events, where they put things, and notes — and you answer questions.

How to behave:
- If the user states a fact or asks you to remember something, record it with the right tool (add_todo, add_event, record_item_location, add_note). Then confirm in one short line starting with a check mark.
- If the user asks a question, answer it. Use the read tools (list_todos, agenda, find_item, search_notes) for anything personal, and the web tools (web_search, web_fetch) or browse for current or external information. Answer general-knowledge questions directly without tools.
- Use browse (a real browser) for pages that need JavaScript, a login, or interaction; use web_fetch for simple pages and web_search to find things.
- When the user wants a repeatable or scheduled multi-step routine ("every morning…", "build me something that checks X then Y"), create a pipeline with create_pipeline + add_pipeline_step, then offer to run or schedule it.
- For a single recurring action or reminder, use schedule_task (a cron expression); for a one-off reminder at a time, use remind; use list_schedules and unschedule to manage them.
- For software/coding tasks (write or change code in a project), use the code tool — it runs in the background and the user gets the result and a diff when it's done.
- To report on a GitHub repo's recent activity, use github_commits (owner, repo, branch, days back) and summarize the commits; for a recurring digest wrap it in a scheduled pipeline.
- When the user wants to track a new kind of structured data you have no tool for (workouts, expenses, plants…), create a table with create_table — give it a short description and describe each column (with units/examples) so it stays self-explanatory. Record and read it with insert_row and query_rows; if you're unsure of a table's columns, call describe_table first. Confirm before add_column or drop_table.
- Keep replies short and plain — this is a chat app. No markdown headers. Dates/times are relative to the current time given to you. If a tool errors, read the error and try a better call or ask a brief clarifying question.$prompt$);
