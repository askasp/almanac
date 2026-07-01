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
-- summary, reminders, pipelines) routes to Signal unchanged. v1 talks in ONE
-- conversation: a designated group (signal_group_id) if set, else 1:1 — Note-to-
-- Self in 'self' mode, or the bot's own number in 'number' mode. Threading
-- matches Telegram — session-window, #slug, /new, and reply/quote to continue.
-- ===========================================================================

SELECT set_cfg('channel',          'signal');            -- 'signal' (default) | 'telegram'
SELECT set_cfg('signal_base_url',  'http://signal:8080');
SELECT set_cfg('signal_number',    '');                  -- auto-detected from the linked account when blank
SELECT set_cfg('signal_mode',      'self');              -- fallback when there's no group: 'self' (Note-to-Self) | 'number'
SELECT set_cfg('signal_group_id',  '');                  -- the group it talks in; auto-managed when blank (signal_ensure)
SELECT set_cfg('signal_group_name','Almanac');           -- name of the group to auto-create / reuse
SELECT set_cfg('signal_auto_group','off');               -- off: QR-linked personal use = Note-to-Self (self-only groups don't receive)

-- Outbound to Signal. p_chat_id is the recipient's number digits; we re-add '+'.
CREATE OR REPLACE FUNCTION signal_send(p_chat_id bigint, p_text text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE base text := cfg('signal_base_url'); num text := cfg('signal_number');
        grp text := cfg('signal_group_id'); resp http_response; ts text;
BEGIN
  IF base IS NULL OR num IS NULL OR num = '' THEN RETURN NULL; END IF;
  resp := almanac_http_post(base || '/v2/send', jsonb_build_object(
            'message',    left(COALESCE(p_text, ''), 4000),
            'number',     num,
            'recipients', CASE WHEN COALESCE(grp,'') <> '' THEN jsonb_build_array(grp)
                               ELSE jsonb_build_array('+' || p_chat_id) END));
  -- Return the sent message's timestamp (Signal's message id). Stored on the
  -- assistant row so the user can quote-reply to it to continue the thread, and
  -- so the idempotency guard drops any echo of our own send.
  IF resp.status BETWEEN 200 AND 299 THEN
    ts := safe_jsonb(resp.content)->>'timestamp';
    IF ts ~ '^[0-9]+$' THEN RETURN ts::bigint; END IF;
  END IF;
  RETURN NULL;
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

-- Idempotent Signal setup so there's nothing to configure by hand: auto-detect
-- the linked account's number, and (personal mode) auto-create or reuse the named
-- group it talks in. Runs from the almanac-signal cron; a no-op once both are
-- known. Re-running from a clean DB just rediscovers the existing group (the
-- group lives in Signal, not the DB), so it's safe to wipe and restart.
CREATE OR REPLACE FUNCTION signal_ensure()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  base text := cfg('signal_base_url'); num text := cfg('signal_number');
  gname text := cfg('signal_group_name','Almanac');
  resp http_response; arr jsonb; g jsonb; gid text;
BEGIN
  IF cfg('channel','signal') <> 'signal' OR base IS NULL THEN RETURN; END IF;

  -- 1) discover the linked account's number (QR-paired personal use)
  IF COALESCE(num,'') = '' THEN
    BEGIN resp := almanac_http_get(base || '/v1/accounts'); EXCEPTION WHEN others THEN RETURN; END;
    IF resp.status BETWEEN 200 AND 299 THEN
      num := safe_jsonb(resp.content)->>0;                          -- ["+47..."]
      IF num IS NULL OR num !~ '^\+' THEN num := safe_jsonb(resp.content)->0->>'number'; END IF;
      IF num ~ '^\+[0-9]+$' THEN PERFORM set_cfg('signal_number', num); ELSE num := ''; END IF;
    END IF;
  END IF;
  IF COALESCE(num,'') = '' THEN RETURN; END IF;                     -- not linked yet

  -- 2) auto-manage the group (personal only; team uses individual DMs, no group)
  IF cfg('team_mode','off') = 'on'
     OR cfg('signal_auto_group','on') <> 'on'
     OR COALESCE(cfg('signal_group_id'),'') <> '' THEN
    RETURN;
  END IF;

  BEGIN resp := almanac_http_get(base || '/v1/groups/' || urlencode(num)); EXCEPTION WHEN others THEN RETURN; END;
  IF resp.status BETWEEN 200 AND 299 THEN
    arr := safe_jsonb(resp.content);
    IF jsonb_typeof(arr) = 'array' THEN
      FOR g IN SELECT value FROM jsonb_array_elements(arr) LOOP
        IF lower(g->>'name') = lower(gname) THEN gid := g->>'id'; EXIT; END IF;
      END LOOP;
    END IF;
  END IF;

  IF COALESCE(gid,'') = '' THEN                                     -- not found → create it
    BEGIN
      resp := almanac_http_post(base || '/v1/groups/' || urlencode(num),
                jsonb_build_object('name', gname, 'members', '[]'::jsonb));
    EXCEPTION WHEN others THEN RETURN; END;
    IF resp.status BETWEEN 200 AND 299 THEN gid := safe_jsonb(resp.content)->>'id'; END IF;
  END IF;

  IF COALESCE(gid,'') <> '' THEN PERFORM set_cfg('signal_group_id', gid); END IF;
END $$;

-- Pull new Signal messages, resolve each to a thread, queue as pending. The
-- receive endpoint drains its own queue, so (unlike Telegram getUpdates) there
-- is no offset to track.
--   mode 'self'   : the sidecar is a linked device on YOUR account (paired by
--                   QR). Only act on your own "Note to Self" thread — a note you
--                   send from your phone arrives as a sync sentMessage to your
--                   own number (some versions deliver it as a dataMessage from
--                   yourself). Your contacts' messages are ignored entirely.
--   mode 'number' : the bot has its own dedicated number; read direct messages.
CREATE OR REPLACE FUNCTION signal_poll()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  base text := cfg('signal_base_url'); num text := cfg('signal_number');
  mode text := cfg('signal_mode','self'); grp text := cfg('signal_group_id');
  self_digits text := NULLIF(regexp_replace(COALESCE(num,''), '\D', '', 'g'), '');
  resp http_response; arr jsonb; e jsonb; dm jsonb; sm jsonb; obj jsonb;
  v_src text; v_digits bigint; v_text text; v_ts bigint; v_reply bigint;
  v_thread bigint; v_slug text; v_content text; cnt int := 0;
BEGIN
  IF cfg('poll_enabled','on') <> 'on' OR num IS NULL OR num = '' THEN RETURN 0; END IF;
  BEGIN
    resp := almanac_http_get(base || '/v1/receive/' || urlencode(num));
  EXCEPTION WHEN others THEN RETURN 0; END;          -- sidecar down / not paired yet
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN 0; END IF;
  arr := safe_jsonb(resp.content);
  IF jsonb_typeof(arr) <> 'array' THEN RETURN 0; END IF;

  FOR e IN SELECT value FROM jsonb_array_elements(arr) LOOP
    v_text := NULL; v_digits := NULL; v_ts := NULL; v_reply := NULL; obj := NULL;
    dm := e->'envelope'->'dataMessage';
    sm := e->'envelope'->'syncMessage'->'sentMessage';

    IF grp <> '' THEN
      -- Designated group: only this group — your own sends (sync sentMessage with
      -- this group, in QR-linked mode) or a dataMessage to the group otherwise.
      -- The reply goes back to the group (signal_send routes by signal_group_id).
      IF sm IS NOT NULL AND (sm->'groupInfo'->>'groupId') = grp THEN
        obj := sm;
      ELSIF dm IS NOT NULL AND (dm->'groupInfo'->>'groupId') = grp THEN
        obj := dm;
      END IF;
      IF obj IS NOT NULL THEN
        v_src := COALESCE(e->'envelope'->>'sourceNumber', e->'envelope'->>'source');
        v_digits := NULLIF(regexp_replace(COALESCE(v_src, ''), '\D','','g'), '')::bigint;
        v_ts := COALESCE((obj->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
      END IF;
    ELSIF mode = 'self' THEN
      -- Only your own Note-to-Self: a note sent from your phone (sync sentMessage
      -- to your number), or a dataMessage from yourself. Contacts are ignored.
      IF sm IS NOT NULL AND sm->'groupInfo' IS NULL
         AND regexp_replace(COALESCE(sm->>'destinationNumber', sm->>'destination', ''), '\D','','g') = self_digits THEN
        obj := sm;
        v_ts := COALESCE((sm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
      ELSIF dm IS NOT NULL AND dm->'groupInfo' IS NULL
            AND regexp_replace(COALESCE(e->'envelope'->>'sourceNumber', e->'envelope'->>'source', ''), '\D','','g') = self_digits THEN
        obj := dm;
        v_ts := COALESCE((dm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
      END IF;
      v_digits := self_digits::bigint;                 -- reply lands in your Note to Self
    ELSE
      -- Dedicated number: read direct messages from the sender (no group).
      IF dm IS NOT NULL AND dm->'groupInfo' IS NULL THEN
        v_src := COALESCE(e->'envelope'->>'sourceNumber', e->'envelope'->>'source');
        IF v_src ~ '^\+[0-9]+$' THEN
          obj := dm;
          v_digits := replace(v_src, '+', '')::bigint;
          v_ts := COALESCE((dm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
        END IF;
      END IF;
    END IF;

    CONTINUE WHEN obj IS NULL;
    v_text := obj->>'message';
    CONTINUE WHEN v_text IS NULL OR btrim(v_text) = '' OR v_digits IS NULL;
    CONTINUE WHEN NOT tg_allowed(v_digits, v_digits);  -- allowlist: list digits, no '+'
    CONTINUE WHEN EXISTS (SELECT 1 FROM messages         -- idempotent receive (no re-processing / echo)
                          WHERE tg_chat_id = v_digits AND tg_message_id = v_ts);
    v_reply := NULLIF(obj->'quote'->>'id', '')::bigint;  -- the quoted message's id, if any
    v_content := v_text; v_thread := NULL;

    -- thread resolution, same precedence as Telegram: /new, quote-reply, #slug, window
    IF lower(btrim(v_text)) ~ '^/new(\s|$)' THEN
      v_thread := new_thread('new');
    END IF;
    IF v_thread IS NULL AND v_reply IS NOT NULL THEN
      SELECT thread_id INTO v_thread FROM messages WHERE tg_message_id = v_reply LIMIT 1;
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

    INSERT INTO messages (thread_id, role, content, status, tg_chat_id, tg_message_id, reply_to_tg_message_id)
    VALUES (v_thread, 'user', v_content, 'pending', v_digits, v_ts, v_reply);
    UPDATE threads SET last_message_at = now() WHERE id = v_thread;
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END $$;

-- The cron calls this; it routes to the active channel's poller.
CREATE OR REPLACE FUNCTION inbound_poll()
RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  IF cfg('channel','signal') = 'telegram' THEN RETURN tg_poll(); END IF;
  RETURN signal_poll();
END $$;
