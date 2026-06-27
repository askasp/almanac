-- ===========================================================================
-- Telegram I/O, entirely in Postgres via pgsql-http long-polling.
-- ===========================================================================

CREATE OR REPLACE FUNCTION gen_slug()
RETURNS text LANGUAGE sql VOLATILE AS $$
  SELECT substr(md5(random()::text || clock_timestamp()::text), 1, 4)
$$;

CREATE OR REPLACE FUNCTION new_thread(p_title text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE s text; tid bigint;
BEGIN
  LOOP
    s := gen_slug();
    BEGIN
      INSERT INTO threads (slug, title) VALUES (s, p_title) RETURNING id INTO tid;
      RETURN tid;
    EXCEPTION WHEN unique_violation THEN
      -- slug collision, try another
    END;
  END LOOP;
END $$;

-- Send a message. Returns the Telegram message_id (for thread chaining), or
-- NULL. Falls back to sending without reply_to if the replied-to msg is gone.
CREATE OR REPLACE FUNCTION tg_send(p_chat_id bigint, p_text text, p_reply_to bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE token text := get_secret('telegram_token'); url text; body jsonb; resp http_response;
BEGIN
  IF token IS NULL THEN RETURN NULL; END IF;
  url  := cfg('tg_api_base','https://api.telegram.org') || '/bot' || token || '/sendMessage';
  body := jsonb_build_object('chat_id', p_chat_id, 'text', left(COALESCE(p_text,''), 4096));
  IF p_reply_to IS NOT NULL THEN
    body := body || jsonb_build_object('reply_to_message_id', p_reply_to);
  END IF;
  resp := almanac_http_post(url, body);
  IF resp.status BETWEEN 200 AND 299 THEN
    RETURN ((resp.content::jsonb)->'result'->>'message_id')::bigint;
  END IF;
  -- retry without reply_to (common cause: replied-to message deleted)
  IF p_reply_to IS NOT NULL THEN
    body := jsonb_build_object('chat_id', p_chat_id, 'text', left(COALESCE(p_text,''), 4096));
    resp := almanac_http_post(url, body);
    IF resp.status BETWEEN 200 AND 299 THEN
      RETURN ((resp.content::jsonb)->'result'->>'message_id')::bigint;
    END IF;
  END IF;
  RETURN NULL;
END $$;

-- Access control: may this sender use the bot? `allowed_chat_ids` is a comma-
-- separated list of Telegram user ids (or chat ids); EMPTY = allow everyone
-- (default). Lock a personal bot to yourself by listing your own id.
CREATE OR REPLACE FUNCTION tg_allowed(p_uid bigint, p_chat bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN btrim(cfg('allowed_chat_ids','')) = '' THEN true
    ELSE EXISTS (
      SELECT 1 FROM regexp_split_to_table(cfg('allowed_chat_ids',''), ',') AS x
      WHERE btrim(x) <> '' AND btrim(x) IN (p_uid::text, p_chat::text)
    )
  END
$$;

-- Pull new updates, resolve each to a thread, queue as pending user messages.
-- Returns the number of text messages ingested.
CREATE OR REPLACE FUNCTION tg_poll()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  token text := get_secret('telegram_token');
  off bigint; resp http_response; updates jsonb; u jsonb; m jsonb;
  v_chat bigint; v_mid bigint; v_text text; v_reply bigint; v_uid bigint;
  v_thread bigint; v_slug text; v_content text; cnt int := 0; maxu bigint;
BEGIN
  IF cfg('poll_enabled','on') <> 'on' OR token IS NULL THEN RETURN 0; END IF;
  SELECT last_update_id INTO off FROM tg_state;

  resp := almanac_http_get(
    cfg('tg_api_base','https://api.telegram.org') || '/bot' || token ||
    '/getUpdates?timeout=0&limit=50&offset=' || (off + 1) ||
    '&allowed_updates=%5B%22message%22%5D');
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN 0; END IF;

  updates := (resp.content::jsonb)->'result';
  IF updates IS NULL OR jsonb_array_length(updates) = 0 THEN RETURN 0; END IF;

  maxu := off;
  FOR u IN SELECT value FROM jsonb_array_elements(updates) LOOP
    maxu := GREATEST(maxu, (u->>'update_id')::bigint);
    m := u->'message';
    CONTINUE WHEN m IS NULL;
    v_text := m->>'text';
    CONTINUE WHEN v_text IS NULL;                       -- skip non-text updates

    v_chat    := (m->'chat'->>'id')::bigint;
    v_mid     := (m->>'message_id')::bigint;
    v_reply   := (m->'reply_to_message'->>'message_id')::bigint;
    v_content := v_text;
    v_thread  := NULL;
    v_uid     := (m->'from'->>'id')::bigint;

    -- access control: drop senders not on the allowlist (empty list = allow all)
    CONTINUE WHEN NOT tg_allowed(v_uid, v_chat);

    -- /new always starts a fresh thread (overrides the session window)
    IF lower(btrim(v_text)) ~ '^/new(\s|$)' THEN
      v_thread := new_thread('new');
    END IF;
    -- 1) a reply to any known message continues that thread
    IF v_thread IS NULL AND v_reply IS NOT NULL THEN
      SELECT thread_id INTO v_thread FROM messages WHERE tg_message_id = v_reply LIMIT 1;
    END IF;
    -- 2) a #slug prefix continues that thread (prefix stripped from content)
    IF v_thread IS NULL AND v_text ~ '^#[A-Za-z0-9]+(\s|$)' THEN
      v_slug := lower(substring(v_text FROM '^#([A-Za-z0-9]+)'));
      SELECT id INTO v_thread FROM threads WHERE slug = v_slug;
      IF v_thread IS NOT NULL THEN
        v_content := btrim(regexp_replace(v_text, '^#[A-Za-z0-9]+\s*', ''));
      END IF;
    END IF;
    -- 3) continue the most-recently-active thread if we're still inside the
    --    session window (natural back-and-forth in one chat)
    IF v_thread IS NULL THEN
      SELECT id INTO v_thread FROM threads
      WHERE status = 'active'
        AND last_message_at >= now() - (cfg('session_window_minutes','30') || ' minutes')::interval
      ORDER BY last_message_at DESC LIMIT 1;
    END IF;
    -- 4) otherwise a fresh thread
    IF v_thread IS NULL THEN
      v_thread := new_thread(left(v_content, 60));
    END IF;

    INSERT INTO messages (thread_id, role, content, status, tg_chat_id,
                          tg_message_id, reply_to_tg_message_id)
    VALUES (v_thread, 'user', v_content, 'pending', v_chat, v_mid, v_reply);
    -- keep the window fresh so the next message groups with this one
    UPDATE threads SET last_message_at = now() WHERE id = v_thread;
    cnt := cnt + 1;
  END LOOP;

  UPDATE tg_state SET last_update_id = maxu;   -- advance past skipped updates too
  RETURN cnt;
END $$;
