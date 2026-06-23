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

-- Generation tunables
SELECT set_cfg('temperature', '0.3');
SELECT set_cfg('max_tokens',  '1024');
SELECT set_cfg('loop_max',    '6');       -- tool-loop iteration cap
SELECT set_cfg('http_timeout','120');     -- seconds, for pgsql-http calls

-- Worker kill-switches (set to 'off' to pause without unscheduling cron)
SELECT set_cfg('poll_enabled',    'on');
SELECT set_cfg('process_enabled', 'on');

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
- Keep replies short and plain — this is a chat app. No markdown headers. Dates/times are relative to the current time given to you. If a tool errors, read the error and try a better call or ask a brief clarifying question.$prompt$);
