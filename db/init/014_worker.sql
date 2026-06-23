-- ===========================================================================
-- The processing worker. Re-entrancy guard: only ever touches role='user'
-- AND status='pending' rows, claimed with FOR UPDATE SKIP LOCKED.
-- ===========================================================================

-- Returns a reply string if the text is a slash/ls command, else NULL.
CREATE OR REPLACE FUNCTION handle_command(p_text text, p_thread_id bigint, p_chat_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE t text := btrim(COALESCE(p_text,'')); w text; v_slug text; cron_e text; out text;
BEGIN
  w := lower(split_part(t, ' ', 1));

  IF w IN ('ls', '/ls', '/threads') THEN
    SELECT string_agg(format('%s  %s  (#%s)',
             to_char(last_message_at,'Mon DD HH24:MI'), COALESCE(title,'(untitled)'), slug),
             E'\n' ORDER BY last_message_at DESC)
    INTO out
    FROM (SELECT * FROM threads WHERE status='active' ORDER BY last_message_at DESC LIMIT 10) x;
    RETURN E'Recent threads (reply to a message, or send "#slug ..." to continue):\n\n'
           || COALESCE(out, '(none yet)');

  ELSIF w = '/start' THEN
    RETURN
      E'Hi — I''m Almanac, your assistant. Just talk to me normally:\n\n'
      || E'  • "dentist tuesday 3pm"        → I''ll add the event\n'
      || E'  • "buy milk"                   → I''ll add a todo\n'
      || E'  • "passports are in the safe"  → I''ll remember where things are\n'
      || E'  • "what''s on today?"          → I''ll show your agenda\n'
      || E'  • "weather in Oslo?"           → I''ll look it up\n\n'
      || E'Reply to any message to continue that conversation. Send "ls" to see recent threads, or /help for more.';

  ELSIF w = '/help' THEN
    RETURN
      E'Almanac — just talk to me in plain text.\n'
      || E'I file todos, events, where you put things, and notes, and answer questions.\n\n'
      || E'Commands:\n'
      || E'  ls                list recent threads\n'
      || E'  /new              start a fresh thread\n'
      || E'  /agenda           today''s events + due todos\n'
      || E'  /pipelines        list your automations\n'
      || E'  /run <slug>       run a pipeline now\n'
      || E'  /schedule <slug> <cron>   schedule a pipeline (e.g. "0 8 * * *")\n\n'
      || E'Continue a conversation by replying to it, or starting with "#slug".';

  ELSIF w = '/new' THEN
    SELECT slug INTO v_slug FROM threads WHERE id = p_thread_id;
    RETURN 'Started a fresh thread #' || COALESCE(v_slug,'?') || '. Go ahead.';

  ELSIF w = '/agenda' THEN
    RETURN execute_tool('agenda', '{}'::jsonb, p_thread_id, NULL);

  ELSIF w = '/pipelines' THEN
    RETURN execute_tool('list_pipelines', '{}'::jsonb, p_thread_id, NULL);

  ELSIF w = '/run' THEN
    v_slug := btrim(substring(t FROM '^/run\s+(\S+)'));
    IF v_slug IS NULL THEN RETURN 'Usage: /run <slug>'; END IF;
    RETURN execute_tool('run_pipeline', jsonb_build_object('slug', v_slug), p_thread_id, NULL);

  ELSIF w = '/schedule' THEN
    v_slug := btrim(substring(t FROM '^/schedule\s+(\S+)'));
    cron_e := btrim(substring(t FROM '^/schedule\s+\S+\s+(.+)$'));
    IF v_slug IS NULL OR cron_e IS NULL THEN RETURN 'Usage: /schedule <slug> <cron-expr>'; END IF;
    RETURN execute_tool('schedule_pipeline', jsonb_build_object('slug', v_slug, 'cron', cron_e),
                        p_thread_id, NULL);
  END IF;

  RETURN NULL;  -- not a command
END $$;

-- Claim and process a batch of pending messages. Per-row subtransaction so one
-- failure doesn't abort the others.
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
    -- remember who the owner is, so cron-triggered pipelines can notify them
    IF r.tg_chat_id IS NOT NULL THEN PERFORM set_cfg('owner_chat_id', r.tg_chat_id::text); END IF;
    BEGIN
      reply := handle_command(r.content, r.thread_id, r.tg_chat_id);
      IF reply IS NULL THEN
        reply := run_thread(r.thread_id, r.id);
      END IF;

      sent := tg_send(r.tg_chat_id, reply, r.tg_message_id);

      INSERT INTO messages (thread_id, role, content, blocks, status, tg_chat_id, tg_message_id)
      VALUES (r.thread_id, 'assistant', reply,
              jsonb_build_object('role','assistant','content',reply),
              'done', r.tg_chat_id, sent);

      UPDATE threads
        SET last_message_at = now(), title = COALESCE(title, left(r.content, 60))
        WHERE id = r.thread_id;

      UPDATE messages SET status='done', processed_at=now() WHERE id = r.id;
      cnt := cnt + 1;

    EXCEPTION WHEN others THEN
      -- roll back this row's work, record the failure, retry later or give up
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
