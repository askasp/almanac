-- ===========================================================================
-- Team mode: one almanac instance per context (personal vs. a team), each its
-- own Telegram bot. Inside a team instance EVERYTHING is shared (todos, calendar,
-- notes, items — it's one database) EXCEPT credentials and email, which are
-- per-member. Members are distinguished by their Telegram user id; their data is
-- attributed so you can see who's working on what; replies route to each member.
--
-- All of this is gated by the `team_mode` config flag. With team_mode='off'
-- (the default) the overridden functions behave EXACTLY as the single-user
-- versions in 013/014/011/018 — the added columns just stay NULL. So this file
-- is safe to ship loaded; you turn team mode on per deployment.
-- ===========================================================================

-- Identity + per-member email -----------------------------------------------
CREATE TABLE members (
  id         bigserial PRIMARY KEY,
  tg_user_id bigint UNIQUE NOT NULL,
  name       text,
  chat_id    bigint,                       -- the member's private chat with the bot
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- A member connects their own inbox(es); the refresh token is encrypted and
-- never visible to other members. (Also covers "several inboxes, summary per
-- account" — a member can have more than one row.)
CREATE TABLE email_accounts (
  id            bigserial PRIMARY KEY,
  member_id     bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  label         text,
  refresh_token bytea,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Attribution: who created each row. Nullable; NULL in personal mode.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS member_id bigint;
ALTER TABLE threads  ADD COLUMN IF NOT EXISTS member_id bigint;
ALTER TABLE todos    ADD COLUMN IF NOT EXISTS member_id bigint;
ALTER TABLE calendar ADD COLUMN IF NOT EXISTS member_id bigint;
ALTER TABLE notes    ADD COLUMN IF NOT EXISTS member_id bigint;
ALTER TABLE items    ADD COLUMN IF NOT EXISTS member_id bigint;

-- Resolve (and keep fresh) a member from a Telegram sender.
CREATE OR REPLACE FUNCTION upsert_member(p_uid bigint, p_name text, p_chat bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE mid bigint;
BEGIN
  INSERT INTO members (tg_user_id, name, chat_id) VALUES (p_uid, p_name, p_chat)
  ON CONFLICT (tg_user_id) DO UPDATE
    SET name    = COALESCE(EXCLUDED.name, members.name),
        chat_id = COALESCE(EXCLUDED.chat_id, members.chat_id)
  RETURNING id INTO mid;
  RETURN mid;
END $$;

-- A "  · Alice" suffix for display, or '' when unattributed / not found.
CREATE OR REPLACE FUNCTION member_name(p_id bigint)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE('  · ' || (SELECT name FROM members WHERE id = p_id), '')
$$;

-- Auto-stamp the current member (set per-message in process_pending, transaction
-- -local so cron/pipeline inserts in other sessions never inherit it).
CREATE OR REPLACE FUNCTION stamp_member()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.member_id IS NULL THEN
    NEW.member_id := NULLIF(current_setting('almanac.current_member', true), '')::bigint;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS todos_stamp_member    ON todos;
DROP TRIGGER IF EXISTS calendar_stamp_member ON calendar;
DROP TRIGGER IF EXISTS notes_stamp_member    ON notes;
DROP TRIGGER IF EXISTS items_stamp_member    ON items;
CREATE TRIGGER todos_stamp_member    BEFORE INSERT ON todos    FOR EACH ROW EXECUTE FUNCTION stamp_member();
CREATE TRIGGER calendar_stamp_member BEFORE INSERT ON calendar FOR EACH ROW EXECUTE FUNCTION stamp_member();
CREATE TRIGGER notes_stamp_member    BEFORE INSERT ON notes    FOR EACH ROW EXECUTE FUNCTION stamp_member();
CREATE TRIGGER items_stamp_member    BEFORE INSERT ON items    FOR EACH ROW EXECUTE FUNCTION stamp_member();

-- tg_poll, now member-aware ---------------------------------------------------
-- Identical to 013 when team_mode='off' (v_member stays NULL, so the session
-- window matches the NULL-member threads, exactly as before).
CREATE OR REPLACE FUNCTION tg_poll()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  token text := get_secret('telegram_token');
  team  boolean := cfg('team_mode','off') = 'on';
  off bigint; resp http_response; updates jsonb; u jsonb; m jsonb;
  v_chat bigint; v_mid bigint; v_text text; v_reply bigint;
  v_thread bigint; v_slug text; v_content text; cnt int := 0; maxu bigint;
  v_uid bigint; v_name text; v_member bigint;
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
    CONTINUE WHEN v_text IS NULL;

    v_chat    := (m->'chat'->>'id')::bigint;
    v_mid     := (m->>'message_id')::bigint;
    v_reply   := (m->'reply_to_message'->>'message_id')::bigint;
    v_content := v_text;
    v_thread  := NULL;
    v_member  := NULL;
    v_uid     := (m->'from'->>'id')::bigint;

    -- Access control: drop senders not on the allowlist (empty list = allow all).
    -- In a team this doubles as a roster gate (only listed ids may join).
    CONTINUE WHEN NOT tg_allowed(v_uid, v_chat);

    -- In a team, identify the sender and keep their member row fresh.
    IF team THEN
      v_name := NULLIF(btrim(COALESCE(m->'from'->>'first_name','') || ' ' ||
                             COALESCE(m->'from'->>'last_name','')), '');
      IF v_uid IS NOT NULL THEN
        v_member := upsert_member(v_uid, COALESCE(v_name, m->'from'->>'username'), v_chat);
      END IF;
    END IF;

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
    -- Session window is scoped to the member (NULL member => the single-user case).
    IF v_thread IS NULL THEN
      SELECT id INTO v_thread FROM threads
      WHERE status = 'active'
        AND member_id IS NOT DISTINCT FROM v_member
        AND last_message_at >= now() - (cfg('session_window_minutes','30') || ' minutes')::interval
      ORDER BY last_message_at DESC LIMIT 1;
    END IF;
    IF v_thread IS NULL THEN
      v_thread := new_thread(left(v_content, 60));
      IF v_member IS NOT NULL THEN UPDATE threads SET member_id = v_member WHERE id = v_thread; END IF;
    END IF;

    INSERT INTO messages (thread_id, role, content, status, tg_chat_id,
                          tg_message_id, reply_to_tg_message_id, member_id)
    VALUES (v_thread, 'user', v_content, 'pending', v_chat, v_mid, v_reply, v_member);
    UPDATE threads SET last_message_at = now() WHERE id = v_thread;
    cnt := cnt + 1;
  END LOOP;

  UPDATE tg_state SET last_update_id = maxu;
  RETURN cnt;
END $$;

-- signal_poll, team-aware. Personal behaviour (group/self/number) is byte-for-
-- byte the 023 version; in team mode the bot uses one shared dedicated number
-- that each member DMs INDIVIDUALLY (no group chat). We identify the member by
-- their phone number, attribute their rows, and reply to each privately. The KB
-- and todos/calendar/notes stay one shared database; only email is per-member.
CREATE OR REPLACE FUNCTION signal_poll()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  base text := cfg('signal_base_url'); num text := cfg('signal_number');
  mode text := cfg('signal_mode','self'); grp text := cfg('signal_group_id');
  team boolean := cfg('team_mode','off') = 'on';
  self_digits text := NULLIF(regexp_replace(COALESCE(num,''), '\D', '', 'g'), '');
  resp http_response; arr jsonb; e jsonb; dm jsonb; sm jsonb; obj jsonb;
  v_src text; v_digits bigint; v_text text; v_ts bigint; v_reply bigint;
  v_name text; v_member bigint;
  v_thread bigint; v_slug text; v_content text; cnt int := 0;
BEGIN
  IF cfg('poll_enabled','on') <> 'on' OR num IS NULL OR num = '' THEN RETURN 0; END IF;
  BEGIN
    resp := almanac_http_get(base || '/v1/receive/' || urlencode(num));
  EXCEPTION WHEN others THEN RETURN 0; END;
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN 0; END IF;
  arr := safe_jsonb(resp.content);
  IF jsonb_typeof(arr) <> 'array' THEN RETURN 0; END IF;

  FOR e IN SELECT value FROM jsonb_array_elements(arr) LOOP
    v_text := NULL; v_digits := NULL; v_ts := NULL; v_reply := NULL; obj := NULL; v_member := NULL;
    dm := e->'envelope'->'dataMessage';
    sm := e->'envelope'->'syncMessage'->'sentMessage';

    IF team THEN
      -- Shared dedicated number: each member DMs it individually. Identify the
      -- member by phone; the reply routes back to them (tg_chat_id = digits).
      IF dm IS NOT NULL AND dm->'groupInfo' IS NULL THEN
        v_src := COALESCE(e->'envelope'->>'sourceNumber', e->'envelope'->>'source');
        IF v_src ~ '^\+[0-9]+$' THEN
          obj := dm;
          v_digits := replace(v_src, '+', '')::bigint;
          v_ts := COALESCE((dm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
          v_name := NULLIF(btrim(e->'envelope'->>'sourceName'), '');
          v_member := upsert_member(v_digits, COALESCE(v_name, v_src), v_digits);
        END IF;
      END IF;
    ELSIF grp <> '' THEN
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
      IF sm IS NOT NULL AND sm->'groupInfo' IS NULL
         AND regexp_replace(COALESCE(sm->>'destinationNumber', sm->>'destination', ''), '\D','','g') = self_digits THEN
        obj := sm;
        v_ts := COALESCE((sm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
      ELSIF dm IS NOT NULL AND dm->'groupInfo' IS NULL
            AND regexp_replace(COALESCE(e->'envelope'->>'sourceNumber', e->'envelope'->>'source', ''), '\D','','g') = self_digits THEN
        obj := dm;
        v_ts := COALESCE((dm->>'timestamp')::bigint, (e->'envelope'->>'timestamp')::bigint);
      END IF;
      v_digits := self_digits::bigint;
    ELSE
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
    CONTINUE WHEN NOT tg_allowed(v_digits, v_digits);
    CONTINUE WHEN EXISTS (SELECT 1 FROM messages WHERE tg_chat_id = v_digits AND tg_message_id = v_ts);
    v_reply := NULLIF(obj->'quote'->>'id', '')::bigint;
    v_content := v_text; v_thread := NULL;

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
        AND member_id IS NOT DISTINCT FROM v_member
        AND last_message_at >= now() - (cfg('session_window_minutes','30') || ' minutes')::interval
      ORDER BY last_message_at DESC LIMIT 1;
    END IF;
    IF v_thread IS NULL THEN
      v_thread := new_thread(left(v_content, 60));
      IF v_member IS NOT NULL THEN UPDATE threads SET member_id = v_member WHERE id = v_thread; END IF;
    END IF;

    INSERT INTO messages (thread_id, role, content, status, tg_chat_id, tg_message_id, reply_to_tg_message_id, member_id)
    VALUES (v_thread, 'user', v_content, 'pending', v_digits, v_ts, v_reply, v_member);
    UPDATE threads SET last_message_at = now() WHERE id = v_thread;
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END $$;

-- process_pending, now setting the per-message member context ----------------
-- Identical to 014 plus: set almanac.current_member (transaction-local) so the
-- attribution trigger stamps new rows, and carry member_id onto the reply.
CREATE OR REPLACE FUNCTION process_pending()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE r record; reply text; sent bigint; cnt int := 0;
BEGIN
  IF cfg('process_enabled','on') <> 'on' THEN RETURN 0; END IF;

  FOR r IN
    SELECT * FROM messages
    WHERE role='user' AND status='pending'
    ORDER BY id
    FOR UPDATE SKIP LOCKED
    LIMIT 5
  LOOP
    UPDATE messages SET status='processing' WHERE id = r.id;
    IF r.tg_chat_id IS NOT NULL THEN PERFORM set_cfg('owner_chat_id', r.tg_chat_id::text); END IF;
    PERFORM set_config('almanac.current_member', COALESCE(r.member_id::text, ''), true);
    BEGIN
      reply := handle_command(r.content, r.thread_id, r.tg_chat_id);
      IF reply IS NULL THEN
        reply := run_thread(r.thread_id, r.id);
      END IF;

      sent := tg_send(r.tg_chat_id, reply, r.tg_message_id);

      INSERT INTO messages (thread_id, role, content, blocks, status, tg_chat_id, tg_message_id, member_id)
      VALUES (r.thread_id, 'assistant', reply,
              jsonb_build_object('role','assistant','content',reply),
              'done', r.tg_chat_id, sent, r.member_id);

      UPDATE threads
        SET last_message_at = now(), title = COALESCE(title, left(r.content, 60))
        WHERE id = r.thread_id;

      UPDATE messages SET status='done', processed_at=now() WHERE id = r.id;
      cnt := cnt + 1;

    EXCEPTION WHEN others THEN
      UPDATE messages
        SET attempts = attempts + 1,
            error    = left(SQLERRM, 1000),
            status   = CASE WHEN attempts + 1 >= 3 THEN 'error' ELSE 'pending' END
        WHERE id = r.id;
      IF r.attempts + 1 >= 3 THEN
        PERFORM tg_send(r.tg_chat_id, 'Sorry — I hit an error handling that.', r.tg_message_id);
      END IF;
    END;
  END LOOP;

  RETURN cnt;
END $$;

-- list_todos, now showing the owner in a team -------------------------------
-- Identical output in personal mode (member_name returns '' for NULL members).
CREATE OR REPLACE FUNCTION tool_list_todos(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_inc boolean := COALESCE((p_args->>'include_done')::boolean, false);
        v_lim int := LEAST(COALESCE((p_args->>'limit')::int, 20), 100);
        v_team boolean := cfg('team_mode','off') = 'on'; out text;
BEGIN
  SELECT string_agg(
           format('- [%s] %s%s%s', CASE WHEN done THEN 'x' ELSE ' ' END, title,
                  COALESCE(' (due ' || to_char(due, 'Mon DD HH24:MI') || ')', ''),
                  CASE WHEN v_team THEN member_name(member_id) ELSE '' END),
           E'\n' ORDER BY done, due NULLS LAST, id)
  INTO out FROM (
    SELECT * FROM todos WHERE v_inc OR NOT done ORDER BY done, due NULLS LAST, id LIMIT v_lim
  ) t;
  RETURN COALESCE(out, 'No todos.');
END $$;

-- Per-member inbox digest (decrypt each account's refresh token, mint an access
-- token, reuse gmail_unread_digest). '' when the member has connected no inbox.
CREATE OR REPLACE FUNCTION member_email_digest(p_member bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  k text := secret_key(); cid text := cfg('gmail_client_id');
  csec text := get_secret('gmail_client_secret');
  a record; rt text; form text; resp http_response; tok text; out text := '';
BEGIN
  IF k IS NULL OR cid IS NULL OR csec IS NULL THEN RETURN ''; END IF;
  FOR a IN SELECT * FROM email_accounts WHERE member_id = p_member ORDER BY id LOOP
    BEGIN
      rt   := pgp_sym_decrypt(a.refresh_token, k);
      form := 'client_id=' || urlencode(cid) || '&client_secret=' || urlencode(csec)
            || '&refresh_token=' || urlencode(rt) || '&grant_type=refresh_token';
      resp := almanac_http_post_form('https://oauth2.googleapis.com/token', form);
      CONTINUE WHEN resp.status NOT BETWEEN 200 AND 299;
      tok := (resp.content::jsonb)->>'access_token';
      out := out || format(E'%s:\n%s\n\n', COALESCE(a.label, 'inbox'), gmail_unread_digest(tok));
    EXCEPTION WHEN others THEN
      out := out || COALESCE(a.label, 'inbox') || ': (unavailable)' || E'\n\n';
    END;
  END LOOP;
  RETURN btrim(out);
END $$;

-- Connect a member's inbox (one-off; refresh token from an OAuth consent flow).
CREATE OR REPLACE FUNCTION team_connect_email(p_member bigint, p_label text, p_refresh text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE k text := secret_key(); aid bigint;
BEGIN
  IF k IS NULL THEN RAISE EXCEPTION 'almanac.secret_key not set'; END IF;
  INSERT INTO email_accounts (member_id, label, refresh_token)
  VALUES (p_member, p_label, pgp_sym_encrypt(p_refresh, k)) RETURNING id INTO aid;
  RETURN 'connected email account #' || aid;
END $$;

-- daily_summary, now per-member in a team ------------------------------------
-- Personal mode: unchanged (one owner). Team mode: each active member gets the
-- shared agenda + todos and their OWN inbox digest.
CREATE OR REPLACE FUNCTION daily_summary()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE chat bigint; ag text; mail text; m record;
BEGIN
  BEGIN ag := execute_tool('agenda', '{}'::jsonb); EXCEPTION WHEN others THEN ag := '(agenda unavailable)'; END;

  IF cfg('team_mode','off') <> 'on' THEN
    chat := NULLIF(cfg('owner_chat_id'), '')::bigint;
    IF chat IS NULL THEN RETURN; END IF;
    BEGIN mail := gmail_fetch(); EXCEPTION WHEN others THEN mail := '(inbox unavailable)'; END;
    PERFORM tg_send(chat, 'Good morning.' || E'\n\n' || ag || E'\n\nInbox:\n' || mail);
    RETURN;
  END IF;

  FOR m IN SELECT * FROM members WHERE is_active AND chat_id IS NOT NULL LOOP
    BEGIN mail := member_email_digest(m.id); EXCEPTION WHEN others THEN mail := ''; END;
    PERFORM tg_send(m.chat_id,
      'Good morning' || COALESCE(', ' || m.name, '') || '.' || E'\n\n' || ag
      || CASE WHEN mail <> '' THEN E'\n\nInbox:\n' || mail ELSE '' END);
  END LOOP;
END $$;
