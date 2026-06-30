-- ===========================================================================
-- Signal channel. A signal-cli-rest-api sidecar (bbernhard/signal-cli-rest-api)
-- holds the bot's registered number and exposes HTTP we poll, exactly like the
-- Telegram Bot API: GET /v1/receive/{number} drains incoming, POST /v2/send
-- sends. Postgres reaches it over the compose network via pgsql-http.
--
-- One `channel` config (telegram|signal) selects which poller the cron runs and
-- where tg_send routes. Signal addresses are E.164 phone numbers; we store the
-- digits (no '+') in messages.tg_chat_id (a bigint — every E.164 number fits)
-- and re-add '+' when sending, so every existing notify path (replies, daily
-- summary, reminders, pipelines) routes to Signal unchanged. v1 is 1:1 only (no
-- groups) and uses session-window / #slug / /new threading (no quote-reply).
-- ===========================================================================

SELECT set_cfg('channel',         'telegram');           -- 'telegram' | 'signal'
SELECT set_cfg('signal_base_url', 'http://signal:8080');
SELECT set_cfg('signal_number',   '');                   -- the bot's number, e.g. +4712345678

-- Outbound to Signal. p_chat_id is the recipient's number digits; we re-add '+'.
CREATE OR REPLACE FUNCTION signal_send(p_chat_id bigint, p_text text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE base text := cfg('signal_base_url'); num text := cfg('signal_number'); resp http_response;
BEGIN
  IF base IS NULL OR num IS NULL OR num = '' THEN RETURN NULL; END IF;
  resp := almanac_http_post(base || '/v2/send', jsonb_build_object(
            'message',    left(COALESCE(p_text, ''), 4000),
            'number',     num,
            'recipients', jsonb_build_array('+' || p_chat_id)));
  RETURN NULL;   -- Signal has no per-message id we thread replies on
END $$;

-- tg_send becomes the channel-aware sender: Signal when channel='signal', else
-- the Telegram implementation (tg_send_telegram, from 013_telegram.sql). Every
-- notify path calls tg_send, so they all route by the active channel.
CREATE OR REPLACE FUNCTION tg_send(p_chat_id bigint, p_text text, p_reply_to bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
BEGIN
  IF cfg('channel','telegram') = 'signal' THEN
    RETURN signal_send(p_chat_id, p_text);
  END IF;
  RETURN tg_send_telegram(p_chat_id, p_text, p_reply_to);
END $$;

-- Pull new Signal messages, resolve each to a thread, queue as pending. The
-- receive endpoint drains its own queue, so (unlike Telegram getUpdates) there
-- is no offset to track.
CREATE OR REPLACE FUNCTION signal_poll()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  base text := cfg('signal_base_url'); num text := cfg('signal_number');
  resp http_response; arr jsonb; e jsonb; dm jsonb;
  v_src text; v_digits bigint; v_text text; v_ts bigint;
  v_thread bigint; v_slug text; v_content text; cnt int := 0;
BEGIN
  IF cfg('poll_enabled','on') <> 'on' OR num IS NULL OR num = '' THEN RETURN 0; END IF;
  BEGIN
    resp := almanac_http_get(base || '/v1/receive/' || urlencode(num));
  EXCEPTION WHEN others THEN RETURN 0; END;          -- sidecar down / not registered yet
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN 0; END IF;
  arr := safe_jsonb(resp.content);
  IF jsonb_typeof(arr) <> 'array' THEN RETURN 0; END IF;

  FOR e IN SELECT value FROM jsonb_array_elements(arr) LOOP
    dm := e->'envelope'->'dataMessage';
    CONTINUE WHEN dm IS NULL;                          -- receipts / typing / sync
    v_text := dm->>'message';
    CONTINUE WHEN v_text IS NULL OR btrim(v_text) = '';
    CONTINUE WHEN dm->'groupInfo' IS NOT NULL;         -- v1: 1:1 only
    v_src := COALESCE(e->'envelope'->>'sourceNumber', e->'envelope'->>'source');
    CONTINUE WHEN v_src IS NULL OR v_src !~ '^\+[0-9]+$';
    v_digits := replace(v_src, '+', '')::bigint;
    CONTINUE WHEN NOT tg_allowed(v_digits, v_digits);  -- allowlist: list digits, no '+'
    v_ts := COALESCE((dm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
    v_content := v_text; v_thread := NULL;

    IF lower(btrim(v_text)) ~ '^/new(\s|$)' THEN
      v_thread := new_thread('new');
    END IF;
    IF v_thread IS NULL AND v_text ~ '^#[A-Za-z0-9]+(\s|$)' THEN
      v_slug := lower(substring(v_text FROM '^#([A-Za-z0-9]+)'));
      SELECT id INTO v_thread FROM threads WHERE slug = v_slug;
      IF v_thread IS NOT NULL THEN
        v_content := btrim(regexp_replace(v_text, '^#[A-Za-z0-9]+\s*', ''));
      END IF;
    END IF;
    IF v_thread IS NULL THEN
      SELECT id INTO v_thread FROM threads
      WHERE status = 'active'
        AND last_message_at >= now() - (cfg('session_window_minutes','30') || ' minutes')::interval
      ORDER BY last_message_at DESC LIMIT 1;
    END IF;
    IF v_thread IS NULL THEN
      v_thread := new_thread(left(v_content, 60));
    END IF;

    INSERT INTO messages (thread_id, role, content, status, tg_chat_id, tg_message_id)
    VALUES (v_thread, 'user', v_content, 'pending', v_digits, v_ts);
    UPDATE threads SET last_message_at = now() WHERE id = v_thread;
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END $$;

-- The cron calls this; it routes to the active channel's poller.
CREATE OR REPLACE FUNCTION inbound_poll()
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  IF cfg('channel','telegram') = 'signal' THEN RETURN signal_poll(); END IF;
  RETURN tg_poll();
END $$;
