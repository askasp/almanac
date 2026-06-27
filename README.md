# Almanac

A personal assistant that lives **entirely in Postgres** and that you talk to from a
single **Telegram** chat. Tell it things in plain text and it files your todos, calendar
events, where you put your things, and notes — and answers questions, searches the web,
drives a real browser, and runs **pipelines** (multi-step routines you or the AI author,
run on demand or on a schedule).

There is no app server. `pg_cron` is the worker, `pgsql-http` makes the outbound calls.
The model runs on **your** hardware via vLLM (OpenAI-compatible) — nothing leaves your box
except the web/Gmail calls you ask for.

```
Telegram ──▶ Postgres (pg_cron workers ─▶ tool dispatcher ─▶ tables)
                 │  └─ pgsql-http ─▶ vLLM (chat) · embeddings · SearXNG · browser · Gmail
                 └─ pipelines: the same tools, sequenced + scheduled
```

## What you can say

Just type naturally — it figures out whether you're recording a fact or asking a question:

| You type | It does |
|---|---|
| `dentist tuesday 3pm` | adds a calendar event |
| `buy milk` | adds a todo |
| `the passports are in the blue drawer` | remembers where things are |
| `where are the passports?` | recalls it |
| `what's on today?` | shows your agenda |
| `remember I prefer aisle seats` | saves a note (semantically searchable) |
| `what did I say about the Berlin trip?` | searches your notes |
| `weather in Oslo?` | searches the web |
| `check the price of flights to tokyo next month` | opens a real browser |
| `every morning, check flight deals to tokyo and DM me` | builds + schedules a pipeline |
| `remind me friday 5pm to call the bank` | sets a one-off reminder |
| `every weekday at 9, remind me to post standup` | schedules a recurring job |
| `track my workouts: type, distance, minutes` | creates a table you can log into |
| `add a healthcheck endpoint to the api project` | runs a coding session (opencode) |

### One chat, many conversations

Everything is one Telegram DM. Context is grouped automatically:

- **Keep talking** and consecutive messages stay in the same conversation (a 30-minute
  session window — configurable).
- **Reply** to any message to jump back into that conversation.
- Start a message with **`#slug`** to continue a specific conversation by its tag.
- Send **`ls`** to list recent conversations (each shows its `#slug`).
- **`/new`** starts a fresh one; **`/help`** shows commands.

## Prerequisites

1. **A Telegram bot token** — message [@BotFather](https://t.me/BotFather), `/newbot`.
2. **A vLLM server** serving an instruct model **with tool-calling enabled**:
   ```bash
   vllm serve Qwen/Qwen2.5-7B-Instruct \
     --enable-auto-tool-choice --tool-call-parser hermes --port 8000
   ```
   Pick a model that's good at function-calling (Qwen2.5/Qwen3-Instruct, Llama-3.3,
   Mistral, Hermes) and the matching `--tool-call-parser`. Intent routing and pipeline
   authoring both depend on reliable tool calls.
3. **An embeddings server** (OpenAI-compatible) — a second vLLM (`--task embed`) or HF
   text-embeddings-inference. Use a **1024-dim** model (e.g. `BAAI/bge-large-en-v1.5`) or
   edit the one `vector(1024)` line in `db/init/002_schema.sql`.
4. **Docker + Docker Compose.**

## Quickstart

```bash
cp .env.example .env
# edit .env: TELEGRAM_TOKEN, ALMANAC_SECRET_KEY (openssl rand -hex 32),
#            LLM_BASE_URL/LLM_MODEL, EMBED_BASE_URL/EMBED_MODEL
docker compose up -d --build
```

That's it. Open Telegram, message your bot, and say hi. The bot starts polling within a
few seconds.

> **Lock it to yourself.** Anyone who finds your bot can message it, so for a personal
> deployment set `ALLOWED_CHAT_IDS` in `.env` to your Telegram user id (get it from
> [@userinfobot](https://t.me/userinfobot); comma-separate several). Empty (the default)
> allows anyone; messages from non-listed senders are silently ignored. In team mode the
> same list gates who may join as a member.

- `db` — Postgres with pg_cron / pgsql-http / pgvector / pgcrypto, all the logic, and the
  scheduled workers.
- `browser` — the Playwright sidecar (built from `mcr.microsoft.com/playwright`).
- `opencode` — coding-agent sidecar; runs `opencode run` against `./workspace` (uses your vLLM).
- `searxng` — the web-search backend.

The model + embeddings run wherever you pointed `LLM_BASE_URL` / `EMBED_BASE_URL` (the
compose file maps `host.docker.internal` to the host so a vLLM on the same machine works).

## Pipelines

A pipeline is an ordered list of steps stored as plain rows. Steps are:

- **tool** — run any tool (`web_search`, `browse`, `add_event`, …) with args that can
  reference earlier outputs via `{{step_N}}`.
- **ai** — a focused sub-agent given a prompt (it can use tools too).
- **notify** — send a Telegram message (defaults to the previous step's output).

You can author one by asking ("build a pipeline that …"), or insert the rows yourself:

```sql
SELECT tool_create_pipeline('{"name":"Tokyo watch","slug":"tokyo"}', NULL, NULL);
SELECT tool_add_pipeline_step('{"slug":"tokyo","kind":"browse","args":{"url":"https://www.google.com/travel/flights?q=flights%20to%20tokyo"}}', NULL, NULL);
SELECT tool_add_pipeline_step('{"slug":"tokyo","kind":"ai","prompt":"From this, give the cheapest fare: {{step_1}}"}', NULL, NULL);
SELECT tool_add_pipeline_step('{"slug":"tokyo","kind":"notify"}', NULL, NULL);
SELECT run_pipeline((SELECT id FROM pipelines WHERE slug='tokyo'), 'manual');
```

Run on demand: `/run tokyo`. Schedule: `/schedule tokyo 0 8 * * *` (adds a `pg_cron` job
`pipeline-tokyo`). Note: heavy sites like Google Flights / Airbnb have anti-bot measures —
scraping may need tuning or an official API.

## Coding, scheduling & custom tables

Three more things you can do by just asking:

- **Code** — "add a healthcheck to the api project" starts an [opencode](https://opencode.ai)
  session in the background (the `opencode` sidecar, pointed at your vLLM). It works on
  whatever you've cloned into `./workspace`, or pass a git URL to clone. You get the result
  and a `git diff` by DM when it finishes — long runs are fine, almanac polls and notifies.
- **Schedule** — "remind me at 5pm to call the bank" sets a one-off reminder; "every weekday
  at 9, remind me to post standup" registers a recurring `pg_cron` job. `schedule_task` runs
  any tool or sends a message on a cron; "what's scheduled?" lists everything; "stop that"
  removes it (core jobs are protected).
- **New tables** — "track my workouts: type, distance, minutes" creates a real table
  (`create_table`) in a dedicated `userdata` schema, recorded in `schema_migrations`. Then
  "log a 5k run, 25 min" and "how far did I run this week?" use `insert_row` / `query_rows`.
  The model never writes SQL — structured tools build the DDL with identifier quoting and a
  type allowlist; `add_column` / `drop_table` confirm first.

## Gmail daily summary (optional)

1. Create a Google Cloud OAuth **Desktop** client; put id/secret in `.env`.
2. `node scripts/oauth.mjs` — approve in the browser; it stores an encrypted refresh token.
3. The `almanac-daily` job (7am) DMs you the agenda + due todos + unread-mail digest.

## Team mode (one instance per context)

Almanac is single-user by default. To run a **shared team instance**, deploy a second copy
with its own bot token and `TEAM_MODE=on` in `.env`. Then:

- Members are recognised by their Telegram user id on first message — no signup.
- Todos, calendar, notes and items are **shared** across the team and **attributed** to
  whoever created them (`list_todos` shows "· Alice"), so you see what everyone's working on.
- **Email and credentials stay private per member** — each connects their own inbox
  (`email_accounts`, via `team_connect_email(...)`), and the daily summary DMs each member
  the shared agenda plus *their own* inbox digest.

Keep your personal almanac as a separate instance (its own bot, `TEAM_MODE=off`). You end up
with one private chat and one team chat — one AI per context, no data co-mingled. With team
mode off, everything behaves exactly as the single-user system above.

## Operating it

```sql
SELECT * FROM cron.job;                              -- the live schedule
SELECT status, count(*) FROM messages GROUP BY 1;    -- nothing should be stuck 'pending'
SELECT name, value FROM config;                      -- tunables
SELECT * FROM actions ORDER BY id DESC LIMIT 20;     -- audit of every tool call
SELECT set_cfg('poll_enabled','off');                -- pause intake without unscheduling
SELECT set_cfg('llm_model','...');                   -- swap the model live
```

Secrets live encrypted in `secrets` (pgcrypto, keyed by `ALMANAC_SECRET_KEY`). Add the
extensibility you want by adding a `tool_<name>(args, thread_id, run_id)` function and a
`register_tool(...)` call — it's instantly available to chat and pipelines alike.

## Tests

A SQL suite exercises the whole system — tool dispatch, the LLM tool-loop, the
inbound→reply worker, threading/commands, pipelines, the KB, and the web/SSRF guard —
with `pgsql-http` and `pg_cron` mocked so responses are deterministic. No Docker needed,
just a local Postgres with `pgvector`:

```bash
./test/run.sh          # → ================  ALL TESTS PASSED  ================
```

## Layout

```
db/                 Postgres image + numbered init scripts (the whole system)
  init/0xx          extensions, schema, secrets, config
  init/01x..018     http, tools, llm loop, telegram, worker, web, pipelines, kb, gmail
  init/019..021     opencode coding jobs, scheduling/reminders, user-created tables
  init/090_cron     scheduled jobs
  init/099_bootstrap.sh   loads secrets/config from env on first init
services/browser    Playwright sidecar (POST /browse)
services/opencode   opencode coding sidecar (POST /code → run a session)
services/searxng    web-search config
workspace/          projects opencode works on (git-ignored; clone your repos here)
scripts/oauth.mjs   one-time Gmail consent
```
