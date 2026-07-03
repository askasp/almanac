# CLAUDE.md — agent guide to Almanac

Orientation for an AI agent working on this repo. Read this first, then
`docs/DEBUGGING.md` when something is broken. User-facing intro is `README.md`.

## What Almanac is

A personal assistant that lives **entirely in Postgres**. You chat with it over
**Signal** (default) or Telegram; it files todos / calendar / notes / item
locations, answers questions, searches the web, drives a browser, runs coding
jobs, and runs multi-step **pipelines** on a schedule. There is **no application
server** — `pg_cron` is the worker/scheduler and `pgsql-http` makes every
outbound HTTP call (LLM, Signal, web, sidecars). Thin sidecar containers
(browser, opencode, searxng, signal-cli) are "hands"; all logic is SQL.

```
Signal/Telegram ─▶ Postgres  (pg_cron workers ─▶ execute_tool dispatcher ─▶ tables)
                       └─ pgsql-http ─▶ LLM (OpenAI-compatible) · Signal · web · sidecars
```

## The one invariant (do not break)

**The model proposes via a whitelisted tool catalog; trusted SQL disposes.**
There is no raw-SQL tool. `execute_tool(name, args jsonb, ...)` is the single
dispatcher shared by the chat loop, pipelines, and cron. When adding tools:
parse args from jsonb, quote identifiers with `format('%I')`, **bind** values —
never concatenate model output into SQL. Never make an LLM/long HTTP call inside
a trigger (re-entrancy + sync `pgsql-http`); workers poll, triggers may only
`pg_notify`.

## Repo layout

```
db/Dockerfile            postgres:17 + pg_cron + pgsql-http + pgvector (+ ca-certificates)
db/init/*.sql|.sh        run ONCE on first cluster init, in filename order:
  001_extensions 002_schema 003_secrets 004_config 010_http 011_tools 012_llm
  013_telegram 014_worker 015_web 016_pipelines 017_kb 018_gmail 019_opencode
  020_schedule 021_userdata 022_github 023_signal 030_team 090_cron
  099_bootstrap.sh   ← copies .env → config/secrets (runs LAST, only on fresh volume)
services/{browser,opencode,searxng}/   sidecars (signal-cli is a stock image)
docker-compose.yml       db + sidecars; db.environment: MUST list every env var bootstrap reads
Makefile                 dev helpers — `make help`
test/{run.sh,suite.sql}  SQL suite vs a throwaway PG; pgsql-http + pg_cron mocked
docs/{SIGNAL,COOKBOOK,DEBUGGING}.md
```

## How a message flows (trace this when debugging)

1. `almanac-poll` cron (5s) → `inbound_poll()` → routes to `signal_poll()` /
   `tg_poll()` → inserts a `messages` row (`role='user'`, `status='pending'`).
2. `almanac-process` cron (5s) → `process_pending()` claims pending rows
   (`FOR UPDATE SKIP LOCKED`) → `handle_command()` (slash/ls) else
   `run_thread()` → `llm_call()` loop + `execute_tool()` per tool_call →
   `tg_send()` the reply → inserts assistant row (`status='done'`).
3. **On error**: `process_pending` catches, writes `messages.error`, bumps
   `attempts`, retries (stays `pending`); after 3 it sets `status='error'` and
   sends the generic **"Sorry — I hit an error handling that."** The real error
   is in `messages.error`, **not** the container logs (it's caught).

## Run / test

```bash
make up            # build + start          make fresh   # wipe DB + reinit (re-runs bootstrap)
make doctor        # ONE-SHOT health check  make logs    # follow db logs
make config        # live config            make errors  # real errors behind "Sorry"
make retry         # re-queue failed msgs    make psql    # shell
./test/run.sh      # SQL suite (needs local PG w/ pgvector; http+cron mocked)
```

## Config & secrets model — the #1 source of confusion

- **`config` table** (`cfg()`/`set_cfg()`): non-secret. Defaults live in
  `004_config.sql` (+ `023_signal.sql`). `.env` overrides them **via bootstrap**.
- **`secrets` table** (pgcrypto, `set_secret()`/`get_secret()`): the symmetric
  key is the GUC `almanac.secret_key`, set by `ALTER DATABASE ... SET` in
  bootstrap. `get_secret` returns NULL if the GUC is unset.
- **Bootstrap runs ONLY on a fresh volume** (first init). Editing `.env` and
  restarting does **nothing** to a DB that already exists — the container gets
  new env vars but `config`/`secrets` are untouched. To apply `.env`:
  `make fresh` (wipes the volume). To patch live without a wipe: `set_cfg()` /
  `set_secret()` in `make psql`.
- `make config` reads the **DB**, never `.env`. "Config doesn't match .env" is
  expected once the DB exists.

## Landmines (already hit and fixed — don't reintroduce)

1. **`psql -c "... :'v' ..."` does NOT interpolate.** psql only expands
   `:'var'`/`:"var"` when reading from **stdin or a file**, never from `-c`. A
   `-c` with `:'v'` sends the literal `:'v'` → `syntax error at or near ":"` →
   under `ON_ERROR_STOP=1` the whole script aborts. `099_bootstrap.sh` therefore
   feeds every statement via a **stdin heredoc**. Keep it that way.
2. **docker-compose `db.environment` must list every var** bootstrap reads.
   Compose auto-loads `.env` only for `${...}` *substitution*; a var reaches the
   container only if it's named in `environment:`. Add new `.env` vars in BOTH
   `099_bootstrap.sh` and `docker-compose.yml`.
3. **`ca-certificates` is required in the db image.** Every `https://` call goes
   through libcurl, which needs `/etc/ssl/certs/ca-certificates.crt`. It's only a
   *recommends* of libcurl, so `--no-install-recommends` drops it; without it TLS
   fails with `error setting certificate file`. It's in the Dockerfile — keep it.
4. **A self-only Signal group can't receive your own messages.** QR-linked
   personal use talks in **Note to Self** (`signal_mode='self'`); auto-group is
   off by default. See `docs/SIGNAL.md`.
5. **Errors are swallowed into `messages.error`.** Don't trust clean container
   logs — `make errors` / `make doctor` is the source of truth.

## Conventions

- Develop on the branch you were assigned; commit with clear messages; don't open
  a PR unless asked. Keep any model identifier out of commits/code/PRs.
- Match surrounding SQL style. New tool = catalog entry + one `execute_tool`
  branch + (usually) a `system_prompt` line in `004_config.sql`.
- New cron work = a trusted function called from `090_cron.sql`, never raw SQL in
  the schedule and never model-authored SQL.
- Add/adjust a `test/suite.sql` block when you change worker/tool/dispatch logic.
