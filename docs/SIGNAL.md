# Using Signal instead of Telegram

Almanac can talk over **Signal**. A `bbernhard/signal-cli-rest-api` sidecar (bundled in
`docker-compose.yml` as the `signal` service) holds the bot's Signal identity and exposes
HTTP; Postgres polls it (`GET /v1/receive`) and sends through it (`POST /v2/send`) exactly
the way it uses the Telegram Bot API. You flip one config value: `channel=signal`. Every
feature — replies, the daily summary, reminders, pipelines, the GitHub digest — routes to
Signal unchanged, because they all go through the same channel-aware sender.

> **v1 scope:** 1:1 direct messages only (no groups); threading uses the session window,
> `#slug`, and `/new` (no quote-reply); recipients are phone numbers (no usernames/UUIDs).

## 1. Give the bot a Signal number

The bot needs its **own** Signal identity — a phone number that can receive an SMS/voice
code and **isn't already on Signal** (a spare SIM, VoIP, Google Voice, etc.). Bring up just
the sidecar first:

```bash
docker compose up -d signal
```

**Register it** (port 8080 is published for this one-time step):

```bash
# 1) Solve a captcha — open the signal-cli captcha page, complete it, and copy the
#    full token that starts with "signalcaptcha://":
#    https://signalcaptchas.org/registration/generate.html

# 2) Request the SMS code (paste the captcha token):
curl -X POST 'http://localhost:8080/v1/register/+4712345678' \
  -H 'Content-Type: application/json' \
  -d '{"captcha":"signalcaptcha://signal-recaptcha-..."}'

# 3) Verify with the code you receive:
curl -X POST 'http://localhost:8080/v1/register/+4712345678/verify/123456'
```

<details>
<summary>Alternative: link to your existing Signal account (advanced)</summary>

```bash
curl 'http://localhost:8080/v1/qrcodelink?device_name=almanac' --output qr.png
# open qr.png, then scan it in Signal → Settings → Linked Devices
```

Caveat: a linked device receives **all** your incoming Signal messages, and v1's 1:1 logic
would try to answer every one. Prefer the dedicated-number route above for a clean bot.
</details>

## 2. Point Almanac at Signal

In `.env` **before first boot**:

```ini
CHANNEL=signal
SIGNAL_NUMBER=+4712345678      # the bot's number you just registered
ALLOWED_CHAT_IDS=4799999999    # YOUR number's digits, no '+' (locks it to you)
```

Or live, without recreating the data volume:

```bash
docker compose exec -T db psql -U almanac -d almanac -c \
  "SELECT set_cfg('channel','signal');
   SELECT set_cfg('signal_number','+4712345678');
   SELECT set_cfg('allowed_chat_ids','4799999999');"
```

## 3. Run and test

```bash
docker compose up -d --build
```

From **your** Signal, message the bot's number ("hi"). It should reply within a few
seconds. Quick checks:

```bash
docker compose logs --tail=30 signal          # registration / receive health
# send straight through the sidecar to confirm the account works:
curl -X POST 'http://localhost:8080/v2/send' -H 'Content-Type: application/json' \
  -d '{"message":"hi from almanac","number":"+4712345678","recipients":["+4799999999"]}'
```

## Notes

- **Switch back to Telegram** anytime: `CHANNEL=telegram` (or `set_cfg('channel','telegram')`).
- **Port 8080** is only needed for registration/linking; afterwards you can drop the `ports:`
  mapping from the `signal` service — the db reaches it over the compose network regardless.
- **Not using Signal?** Delete the `signal` service (and its line in `db.depends_on`) from
  `docker-compose.yml`; nothing else needs it when `channel=telegram`.
- Registration data lives in `./signal-data` — back it up; re-registering needs the number again.
- The allowlist for Signal matches your number's **digits** (no `+`). Empty = anyone can
  message the bot.
