# Almanac Cookbook — realistic uses, what's default, what to set up

Worked examples of how you'd actually use Almanac from Telegram. For each one:

- **You say** — what you type to the bot.
- **In place by default** — what already works once the stack is running.
- **Setup (run once)** — the exact commands, or "none."

### Before any of this

1. The stack is up and your models are reachable:
   ```bash
   docker compose up -d --build         # db + browser + opencode + searxng
   # LLM_BASE_URL / EMBED_BASE_URL point at your vLLM + embeddings server
   ```
2. **Message the bot once.** The first message you send is remembered as the
   owner (`owner_chat_id`), which is where every cron-initiated DM (daily
   summary, scheduled pipelines, reminders) is sent. Without it those jobs have
   nowhere to deliver.

Setup commands below are SQL against the `db` container. For brevity they're
written as `psql -c "…"`; the real form is:

```bash
docker compose exec -T db psql -U almanac -d almanac -c "<SQL>"
```

---

## 1. Ask general questions

> **You say:** "What's the capital of Mongolia?"
> "What's the weather in Oslo right now?"
> "Summarize https://example.com/some-article"

**In place by default:** Everything. The model answers general knowledge
directly; for anything current/external it reaches for `web_search` (bundled
SearXNG), `web_fetch` (simple pages), or `browse` (the Playwright sidecar, for
JS-heavy pages and logins).

**Setup (run once):** None.

---

## 2. Record & recall — todos, calendar, where-you-put-things, notes

> **You say:** "buy milk" · "dentist Tuesday 3pm" · "passports are in the safe"
> "remember the spare key is with the neighbour"
> **Later:** "what's on today?" · "where are the passports?" · "what did I say about the spare key?"

**In place by default:** Everything. The model files each statement with the
right tool (`add_todo`, `add_event`, `record_item_location`, `add_note`) and
reads it back (`agenda`, `find_item`, `list_todos`, `search_notes`).

**Setup (run once):** None.

---

## 3. Reminders & recurring nudges

> **You say:** "remind me at 5pm to call the bank" (one-off)
> "every weekday at 9 remind me to post standup" (recurring)
> "what's scheduled?" · "stop the standup reminder"

**In place by default:** Everything. One-offs use `remind` and fire via the
`almanac-remind` cron (every minute). Recurring ones use `schedule_task`, which
registers a `task-<id>` cron job. `list_schedules` / `unschedule` manage them.

**Setup (run once):** None.

**Inspect:**
```sql
psql -c "SELECT * FROM reminders WHERE NOT sent;"
psql -c "SELECT jobname, schedule FROM cron.job WHERE jobname LIKE 'task-%';"
```

---

## 4. Semantic notes (knowledge base)

> **You say:** "remember I like aisle seats and my passport expires in March 2027"
> **Weeks later:** "what do I need to know before booking a flight?"

**In place by default:** Notes are embedded with pgvector. The `almanac-kb`
cron (every minute) embeds new notes; `search_notes` does semantic recall and
falls back to keyword search if the embeddings server is unreachable.

**Setup (run once):** None beyond having `EMBED_BASE_URL` point at a running
embeddings model (it's part of the standard stack). Confirm embeddings are
flowing:
```sql
psql -c "SELECT count(*) FILTER (WHERE embedding IS NULL) AS pending,
                count(*) AS total FROM notes;"   -- pending should trend to 0
```

---

## 5. Track a custom thing — self-describing tables

> **You say:** "track my workouts: kind (run/bike/swim, required), distance in km, minutes"
> "log a 5k run, 25 minutes" · "how far did I run this week?"
> "what tables do I have?" · "describe workouts"

**In place by default:** Everything. `create_table` makes a real table in the
`userdata` schema and stores your descriptions as Postgres `COMMENT`s, so the
model can later `describe_table` and know exactly how to fill and query it.
`insert_row` / `query_rows` do the CRUD; `add_column` / `drop_table` ask for
confirmation first.

**Setup (run once):** None — just say what you want to track.

**Inspect:**
```sql
psql -c "SELECT name, applied_at FROM schema_migrations ORDER BY id;"
psql -c "\d userdata.workouts"
```

---

## 6. Do some coding

> **You say:** "in the project at /workspace/api add a /health endpoint and a test"
> "clone https://github.com/me/scripts and make the backup script idempotent"

**In place by default:** The `code` tool drives the opencode sidecar (using your
same vLLM). It runs **async**: you get "🛠️ Started coding job #N" immediately,
and the `almanac-code` cron (every 20s) DMs you the result + a `git diff` when
it finishes. It works on the mounted `./workspace` or an on-demand `git clone`.

**Setup (run once):** For the mounted workspace, drop a repo into it on the host:
```bash
git clone https://github.com/me/api ./workspace/api
```
Then reference it as `/workspace/api`. No SQL needed. (Public repos clone
straight from chat via `repo:`; **private** repos need credentials baked into
the clone URL or a mounted credential — not handled out of the box.)

**Inspect:**
```sql
psql -c "SELECT id, status, left(prompt,40) FROM code_jobs ORDER BY id DESC LIMIT 5;"
```

---

## 7. Track flights to Tokyo

There's no built-in flight tracker, but every building block is present:
`browse`, `web_search`, pipelines, `schedule_pipeline`, and custom tables. You
assemble it in one sentence.

> **You say:** "build a pipeline that checks Google Flights for OSL→Tokyo next
> month, picks the cheapest, and DMs me — run it every morning at 8"

**In place by default:** The model authors it with `create_pipeline` +
`add_pipeline_step` (a `browse` step → an `ai` step that extracts the cheapest →
a `notify` step) and `schedule_pipeline`, which creates a `pipeline-<slug>` cron
job. Authoring and scheduling need **no** setup.

**Setup (run once):** None to author it. To drive/inspect it explicitly:
```sql
-- see it and its schedule
psql -c "SELECT slug, name, cron_expr FROM pipelines;"
psql -c "SELECT jobname, schedule FROM cron.job WHERE jobname LIKE 'pipeline-%';"
-- run it now instead of waiting for 8am
psql -c "SELECT run_pipeline((SELECT id FROM pipelines WHERE slug='tokyo'), 'manual');"
```

**Want price history too?** Pair it with a self-describing table:

> **You say:** "track tokyo flight prices: checked_on (date), price_nok (number),
> airline (text)" — then in the pipeline's last step, "insert today's cheapest
> into tokyo_prices."
> **Later:** "how have Tokyo prices moved this month?"

**Caveat (be realistic):** Google Flights and airline sites are heavy SPAs with
anti-bot measures and ToS limits — `browse` scraping can be brittle or blocked.
Where a real flight-price API exists, point a `web_fetch`/`code`-built step at it
instead; it's far sturdier than scraping.

---

## 8. Daily email summary (7am)

> **You get, every morning:** "Good morning." + today's agenda & due todos +
> a digest of your unread Gmail from the last day.

**In place by default:** The `almanac-daily` cron is already scheduled for
`0 7 * * *` and runs `daily_summary()`. The **agenda + todos** half works with
no setup. The **inbox** half needs Gmail connected, and the whole thing needs to
know where to send (so message the bot once first).

**Setup (run once):**

1. Make sure the owner is known (message the bot once), then verify:
   ```sql
   psql -c "SELECT cfg('owner_chat_id');"   -- should be your chat id, not empty
   ```
2. Connect Gmail (for the inbox digest):
   - Create a Google Cloud OAuth **Desktop app** client. Put its id/secret in
     `.env` as `GMAIL_CLIENT_ID` / `GMAIL_CLIENT_SECRET` (or set them live):
     ```sql
     psql -c "SELECT set_cfg('gmail_client_id','<id>');
              SELECT set_secret('gmail_client_secret','<secret>');"
     ```
   - Run the one-time consent (opens a browser, stores an encrypted refresh
     token via `gmail_set_refresh()`):
     ```bash
     GMAIL_CLIENT_ID=<id> GMAIL_CLIENT_SECRET=<secret> node scripts/oauth.mjs
     ```
3. (Optional) move it off 7am — just re-schedule the same job:
   ```sql
   psql -c "SELECT cron.schedule('almanac-daily','0 8 * * *','SELECT daily_summary()');"
   ```

**Test immediately (don't wait until morning):**
```sql
psql -c "SELECT gmail_fetch();"     -- just the inbox digest
psql -c "SELECT daily_summary();"   -- the full 7am DM, right now
```

> Team instances (`team_mode='on'`) do this **per member**: each connects their
> own inbox with `team_connect_email(...)` and gets their own digest DM'd — the
> shared agenda plus their private mail.

---

## 9. Lock the bot to yourself (recommended)

By default anyone who finds your bot can message it. Restrict it:

> **You set:** your Telegram user id (from [@userinfobot](https://t.me/userinfobot)).

**In place by default:** No restriction — empty allowlist means everyone.

**Setup (run once):**
```sql
psql -c "SELECT set_cfg('allowed_chat_ids','123456789');"   -- comma-separate several
```
Or set `ALLOWED_CHAT_IDS=123456789` in `.env` before first boot. Messages from
anyone not listed are silently ignored; in a team instance the same list gates
who may join as a member.

---

## Appendix — health & inspection queries

```sql
-- the whole live schedule (standing jobs + your pipelines/tasks)
psql -c "SELECT jobname, schedule, active FROM cron.job ORDER BY jobname;"

-- message pipeline health: nothing should be stuck in 'pending'/'processing'
psql -c "SELECT status, count(*) FROM messages GROUP BY status;"

-- recent tool calls (the audit log)
psql -c "SELECT created_at, tool_name FROM actions ORDER BY id DESC LIMIT 20;"

-- config + which secrets are set (values never shown)
psql -c "SELECT key, value FROM config ORDER BY key;"
psql -c "SELECT name FROM secrets ORDER BY name;"

-- pause the workers without unscheduling cron (kill-switch)
psql -c "SELECT set_cfg('poll_enabled','off'); SELECT set_cfg('process_enabled','off');"
```
