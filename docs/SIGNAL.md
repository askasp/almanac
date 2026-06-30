# Using Signal instead of Telegram

Almanac can talk over **Signal**. A `bbernhard/signal-cli-rest-api` sidecar (bundled in
`docker-compose.yml` as the `signal` service) holds the Signal identity and exposes HTTP;
Postgres polls it (`GET /v1/receive`) and sends through it (`POST /v2/send`) exactly the
way it uses the Telegram Bot API. You flip one config value — `channel=signal` — and every
feature (replies, daily summary, reminders, pipelines, the GitHub digest) routes to Signal
unchanged, because they all go through the same channel-aware sender.

There are two ways to give it a Signal identity. **Pick one:**

| | `SIGNAL_MODE=self` (recommended) | `SIGNAL_MODE=number` |
|---|---|---|
| Setup | **Scan a QR** with your Signal app | Register a **separate** number (+ captcha) |
| Needs a spare number? | **No** | Yes (one that can receive SMS, not on Signal) |
| How you chat with it | In your **"Note to Self"** | You DM the bot's number |
| What it can see | Only your Note to Self | Direct messages to the bot |

> **v1 scope:** 1:1 only (no groups); recipients are phone numbers (no usernames/UUIDs).
> Threading works like Telegram: the session window, `#slug`, `/new`, and **reply/quote** a
> message to continue its thread.

---

## Option A — pair by QR (recommended, no spare number)

The sidecar becomes a **linked device** on *your* Signal account (like Signal Desktop), and
Almanac only ever reads/writes your **Note to Self** chat — it ignores all your other
conversations.

1. Bring up just the sidecar (port 8080 is published for pairing):
   ```bash
   docker compose up -d signal
   ```
2. Get the linking QR and scan it:
   ```bash
   curl 'http://localhost:8080/v1/qrcodelink?device_name=almanac' --output qr.png
   ```
   Open `qr.png`, then in your phone: **Signal → Settings → Linked Devices → + → scan**.
3. Configure Almanac (`.env`):
   ```ini
   CHANNEL=signal
   SIGNAL_MODE=self
   SIGNAL_NUMBER=+4799999999      # YOUR own number (the account you just linked)
   ALLOWED_CHAT_IDS=4799999999    # your number's digits, no '+'
   ```
4. `docker compose up -d --build`, then open your **Note to Self** chat in Signal and say
   "hi". Almanac replies right there.

---

## Option B — dedicated bot number

The bot gets its **own** Signal identity — a number that can receive an SMS code and **isn't
already on Signal** (spare SIM, VoIP, Google Voice…). You then DM that number.

```bash
docker compose up -d signal
# 1) Solve a captcha (open the signal-cli captcha page, complete it, copy the full
#    token starting "signalcaptcha://"):  https://signalcaptchas.org/registration/generate.html
# 2) Request the SMS code:
curl -X POST 'http://localhost:8080/v1/register/+4712345678' \
  -H 'Content-Type: application/json' -d '{"captcha":"signalcaptcha://signal-recaptcha-..."}'
# 3) Verify:
curl -X POST 'http://localhost:8080/v1/register/+4712345678/verify/123456'
```

```ini
CHANNEL=signal
SIGNAL_MODE=number
SIGNAL_NUMBER=+4712345678      # the bot's number you registered
ALLOWED_CHAT_IDS=4799999999    # YOUR number's digits, no '+'
```

Then `docker compose up -d --build` and DM the bot's number from your Signal.

---

## Verify / operate

```bash
docker compose logs --tail=30 signal           # pairing / receive health
# send straight through the sidecar to confirm the account works:
curl -X POST 'http://localhost:8080/v2/send' -H 'Content-Type: application/json' \
  -d '{"message":"hi from almanac","number":"+4799999999","recipients":["+4799999999"]}'
```

Change config live (without recreating the data volume):
```bash
docker compose exec -T db psql -U almanac -d almanac -c \
  "SELECT set_cfg('channel','signal'); SELECT set_cfg('signal_mode','self');
   SELECT set_cfg('signal_number','+4799999999');"
```

## Notes

- **Switch back to Telegram** anytime: `CHANNEL=telegram`.
- **Port 8080** is only needed for pairing/registration; you can drop the `ports:` mapping
  from the `signal` service afterwards (the db reaches it over the compose network anyway).
- **Not using Signal?** Delete the `signal` service (and its `db.depends_on` line) from
  `docker-compose.yml`; nothing else needs it when `channel=telegram`.
- Pairing/registration data lives in `./signal-data` — back it up.
- `self` is the default mode *on purpose*: if you pair by QR but forget to set the mode, the
  worst case is "the bot stays quiet," never "the bot answers my contacts."
- Exact Note-to-Self delivery can vary slightly by signal-cli version. If `self` mode never
  ingests your messages, check `docker compose logs signal` and try Option B as a fallback.
