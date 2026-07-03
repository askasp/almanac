# Debugging Almanac

A runbook for "I said something and got no reply / an error." Almanac catches
errors and only sends a generic **"Sorry — I hit an error handling that."** to
chat — the real error is always saved in the database. This tells you where to
look.

## Start here: `make doctor`

```bash
make doctor
```

One shot, five sections. Read them top-down — the first one that's wrong is your bug:

| Section | Healthy looks like | If wrong |
|---|---|---|
| **0. containers** | `db` = `Up` (not `Restarting`/`Exited`) | container/build problem → see *Container won't stay up* |
| **1. bootstrap** | `[almanac] bootstrap complete.` | `.env` not applied → see *Config & secrets* |
| **2. config** | `llm_base_url` = your real URL, not `host.docker.internal:8000` | stale/default config → *Config & secrets* |
| **3. secrets** | `key_set = t`, `llm_api_key` preview `sk-or-`/your prefix | GUC or key missing → *Config & secrets* |
| **4. errors** | (empty) | there's your error text → *Common errors* below |
| **5. tool calls** | recent tools with results | shows which tool failed and why |

If `make doctor` itself **hangs**, the db container is unhealthy — Ctrl-C and run
the bounded `docker compose ps` + `docker compose logs db --tail 40` directly.

## The message lifecycle (where things get stuck)

```
inbound_poll() ─▶ messages(role=user,status=pending) ─▶ process_pending()
   (5s cron)                                              ├─ handle_command()  (ls, /new, /agenda…)
                                                          └─ run_thread() ─▶ llm_call() loop ─▶ execute_tool()
                                                                                    └─▶ tg_send() reply ─▶ messages(assistant,done)
```

Inspect each stage in `make psql`:

```sql
-- did the message even arrive?
SELECT id,status,role,left(content,50),error FROM messages ORDER BY id DESC LIMIT 10;
-- stuck 'pending' (worker not running?) vs 'error' (it failed) vs 'done' (ok)
SELECT status, count(*) FROM messages GROUP BY 1;
-- is the poll/process cron actually firing?
SELECT jobname, last_run_status, last_run_start
FROM cron.job j LEFT JOIN LATERAL (
  SELECT status last_run_status, start_time last_run_start
  FROM cron.job_run_details WHERE jobid=j.jobid ORDER BY start_time DESC LIMIT 1) d ON true
WHERE jobname LIKE 'almanac-%';
```

- **All messages stuck `pending`** → the `almanac-process` worker isn't running,
  or `process_enabled`/`poll_enabled` is `off` (kill-switches in `config`). Check
  `cron.job_run_details` for failures.
- **`error` rows** → read `messages.error` (that's the real exception).
- **Nothing arrives at all** → inbound side: `make signal-logs` (are envelopes
  coming in?), `make config` (right `channel`/`signal_mode`?). See `docs/SIGNAL.md`.

After you fix a cause, re-drive the failed messages without re-sending from your
phone:

```bash
make retry      # sets error/stuck rows back to pending; the worker re-processes
```

## Common errors (from `messages.error` / `make errors`)

| `error` text | Cause | Fix |
|---|---|---|
| `Failed to connect to host.docker.internal port 8000` | config still on the vLLM default → `.env` never loaded | *Config & secrets* below; almost always bootstrap didn't run |
| `error setting certificate file: /etc/ssl/certs/ca-certificates.crt` | db image missing the CA bundle for TLS | `ca-certificates` in `db/Dockerfile`, then `docker compose up -d --build` |
| `almanac.secret_key is not set; cannot store secrets` | GUC unset → bootstrap skipped (empty `ALMANAC_SECRET_KEY`) | set a real key in `.env`, `make fresh` |
| `LLM HTTP 401 / 403 / No auth credentials` | bad/missing `llm_api_key` | real key; `make fresh` or `set_secret('llm_api_key', …)` |
| `LLM HTTP 404 / model not found` | `llm_model` not valid on the provider | set a valid model (e.g. `openai/gpt-4o-mini`) |
| `LLM HTTP 400 …` | malformed request / model doesn't support tools | pick a tool-calling model; check `llm_call` body |
| generic "Sorry" but `messages.error` empty | it succeeded on retry, or the failure was in `tg_send` (outbound) | check `make actions` and `make signal-logs` |

## Config & secrets (the usual root cause)

**Mental model:** `.env` is a *seed*, copied into the `config`/`secrets` tables
**once**, by `db/init/099_bootstrap.sh`, **only on first cluster init (empty
volume)**. After that the DB is the source of truth. Restarting with a new `.env`
changes the container's env vars but **not** the tables.

```
.env ──(docker compose, ${VAR} substitution)──▶ db container env
     ──(099_bootstrap.sh, ONLY on fresh volume)──▶ config + secrets tables
     ──(cfg()/get_secret() at runtime)──▶ the app
```

Two failure points on that chain, both real bugs we've fixed — verify them if
`.env` "isn't being read":

1. **Is the var passed into the container?** `docker compose exec db printenv | grep LLM_BASE_URL`.
   If blank, the var isn't listed in `docker-compose.yml` `db.environment:` (it
   must be — Compose only auto-loads `.env` for `${...}` substitution, not for
   container env). Every var `099_bootstrap.sh` reads must appear there.
2. **Did bootstrap actually run?** `docker compose logs db 2>&1 | grep "almanac\]"`.
   - `bootstrap complete.` → ran; if config is still default, the specific var
     was empty in `.env`.
   - `ALMANAC_SECRET_KEY is empty — skipping` → the gate: set a real key.
   - **nothing** → it errored mid-run (init aborts under `ON_ERROR_STOP=1`); look
     for the failing statement in the logs.

**Apply `.env` changes** = `make fresh` (wipes the volume so bootstrap re-runs).
**Patch live without a wipe** (keeps data):

```sql
-- in `make psql`
SELECT set_cfg('llm_base_url','https://openrouter.ai/api');
SELECT set_cfg('llm_model','openai/gpt-4o-mini');
SELECT set_secret('llm_api_key','sk-or-…');   -- needs the GUC set (bootstrap ran once)
```

Verify secrets decrypt (needs the GUC + matching key):

```sql
SELECT secret_key() IS NOT NULL AS key_set;
SELECT name, left(get_secret(name),6) AS preview FROM secrets ORDER BY name;
```

### psql `:'var'` interpolation — a bootstrap landmine

`psql -c "SELECT set_cfg('x', :'v')"` does **not** work: psql expands `:'var'` /
`:"var"` only when reading from **stdin or a file**, never from `-c`. Via `-c`
the literal `:'v'` reaches the server → `syntax error at or near ":"` → with
`ON_ERROR_STOP=1` the whole bootstrap aborts on its first statement and silently
loads nothing. `099_bootstrap.sh` feeds SQL via **stdin heredocs** for this
reason. If you touch it, keep that shape and reproduce locally (below).

## Container won't stay up

```bash
docker compose ps                 # db = Restarting/Exited?
docker compose logs db --tail 60  # bounded — the crash reason
```

- **Build failed** (e.g. `apt-get` couldn't fetch behind a proxy) → the old image
  may still be running; re-run `docker compose up -d --build` and watch the build.
- **Init script errored** on a fresh volume → the failing `.sql`/`.sh` line is in
  the logs; a bad init aborts startup. Fix the file, `make fresh`.
- **pg_cron `FATAL: database "almanac" does not exist`** early in the logs is
  **normal** — the pg_cron launcher connects before the DB is created, then
  retries. Not an error.

## Reproduce the bootstrap locally (no Docker needed)

The bootstrap is pure psql; you can prove it against a throwaway cluster with a
non-root user (postgres refuses to run as root):

```bash
export PGDATA=/tmp/pgtest PGPORT=54321 PGHOST=/tmp
/usr/lib/postgresql/*/bin/initdb -D "$PGDATA" -U almanac --auth=trust
/usr/lib/postgresql/*/bin/pg_ctl -D "$PGDATA" -o "-c unix_socket_directories=/tmp -p $PGPORT" -w start
createdb -h /tmp -p $PGPORT -U almanac almanac
# load pgcrypto + 003_secrets.sql's functions, set the env vars a real .env would
# have, then run db/init/099_bootstrap.sh with PGHOST/PGPORT exported and verify
# get_secret()/cfg() return your values from a FRESH connection.
```

This is how the `:'var'` bug was found: `SELECT :'k'` via `-c` errored, via stdin
worked.

## Running the SQL test suite

```bash
./test/run.sh      # needs a local PG with pgvector; pgsql-http + pg_cron are mocked
```

`test/suite.sql` exercises the dispatcher, worker, threading, channels, tools.
Add a block when you change any of that. HTTP is mocked via `http_mock_queue`.

## Kill-switches & knobs (in `config`)

```sql
SELECT set_cfg('poll_enabled','off');     -- stop ingesting
SELECT set_cfg('process_enabled','off');  -- stop replying (messages pile up as pending)
SELECT set_cfg('http_timeout','120');     -- pgsql-http seconds
SELECT set_cfg('loop_max','6');           -- max tool-call iterations per turn
```
