# Signal (the default channel)

Almanac talks over **Signal** by default, through a bundled `signal-cli-rest-api`
sidecar that Postgres polls over HTTP. It's **self-configuring**: you pair it to your
Signal once by QR, and it auto-detects your number and talks to you in your **"Note to
Self"** chat. There's nothing to put in `.env` for Signal beyond `CHANNEL=signal`.

> **Scope:** one private conversation (the Almanac group), 1:1. Threading works like
> Telegram — session window, `#slug`, `/new`, and reply/quote a message to continue it.

## Quick start

```bash
cp .env.example .env          # set ALMANAC_SECRET_KEY + your LLM_* (OpenRouter/vLLM)
make up                       # build + start everything (CHANNEL=signal by default)
make qr                       # fetches qr.png
#  → scan qr.png in Signal → Settings → Linked Devices → +
```

That's it. Within a few seconds the cron auto‑detects your number — open your **Note to Self**
chat in Signal and say "hi".

Check it came up:
```bash
make config        # channel=signal, signal_number=+47…, signal_group_id=group.…
make messages      # your message + the reply
```

## How the auto-setup works

A once-a-minute job (`signal_ensure`) does, idempotently:

1. **Number** — if `signal_number` is blank, read it from the linked account (`GET /v1/accounts`).
2. **(Optional) group** — off by default (`SIGNAL_AUTO_GROUP=off`). QR‑linked personal use
   talks in **Note to Self**, which reliably syncs to the linked device. A *self‑only* group
   can't receive your own messages, so auto‑group is off; turn it on only if the group has
   other members.

So a clean start needs no manual ids. Override with `SIGNAL_NUMBER` or `ALLOWED_CHAT_IDS`.

## Start fresh (for testing)

```bash
make fresh        # wipe the DB, restart; KEEPS the Signal pairing (no re-scan).
                  # The Almanac group is re-discovered automatically.
make fresh-hard   # also wipe the pairing — you'll re-scan the QR (make qr).
```

## Alternatives

- **A dedicated group instead of Note-to-Self:** `SIGNAL_AUTO_GROUP=on` — but only worthwhile
  if the group has **other members**; a self‑only group won't deliver your own messages to the
  linked device.
- **Dedicated bot number** (most robust; needed for team): instead of QR-linking your own
  account, register a separate number — `docker compose up -d signal`, then
  `POST /v1/register/<number>` (with a captcha token from the signal-cli captcha page) and
  `POST /v1/register/<number>/verify/<code>`. Set `SIGNAL_MODE=number`, `SIGNAL_NUMBER=<it>`,
  `SIGNAL_GROUP_ID=` empty, and DM that number.
- **Team — several people, one shared instance:** `TEAM_MODE=on` + a **dedicated number**
  (above). Each member DMs it from their own Signal; the bot identifies them by phone,
  shares the KB / todos / calendar / notes (attributed), and replies to each **privately**.
  No group; all 1:1. Put each member's digits (no `+`) in `ALLOWED_CHAT_IDS` as the roster.

## Troubleshooting

```bash
make signal-logs    # raw envelopes — the ground truth for what arrives & in what shape
make config         # what channel/number/group the DB actually has
```

| Symptom | Fix |
|---|---|
| QR "link failed" | The sidecar must be in `MODE: normal` to link a fresh account (it is by default). Scan **promptly** — the QR expires in a minute or two. |
| `signal_number` stays blank | Not linked yet, or `make qr` not scanned. Check `make signal-logs`. |
| No Almanac group appears | The auto-create can fail on some signal-cli versions if a group needs ≥1 member — just create a group named **Almanac** in the app; the job will find it. |
| Messages in `signal-logs` but 0 ingested | Your own sends may arrive in a shape the parser doesn't match — paste me a `signal-logs` line. Or use a dedicated number (bulletproof). |
| Changed `.env`, nothing changed | `.env` loads only on first DB init. Use `make fresh`, or `set_cfg(...)` live. |

The `id` the group is created/found with must match the `groupId` in received messages —
normally the same string from `GET /v1/groups`. If the group exists but messages still don't
ingest, `make signal-logs` shows the received `groupId`; tell me if it differs from
`make config`'s `signal_group_id` and I'll reconcile them.
