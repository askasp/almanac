-- ===========================================================================
-- Gmail daily summary (single-user, one encrypted refresh token).
-- One-time consent is done by scripts/oauth.mjs, which calls gmail_set_refresh().
-- ===========================================================================

CREATE OR REPLACE FUNCTION gmail_set_refresh(p_token text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE k text := secret_key();
BEGIN
  IF k IS NULL THEN RAISE EXCEPTION 'almanac.secret_key not set'; END IF;
  UPDATE gmail_auth SET refresh_token = pgp_sym_encrypt(p_token, k),
                        access_token = NULL, expires_at = NULL;
END $$;

-- Exchange the refresh token for a fresh access token; store it encrypted.
CREATE OR REPLACE FUNCTION gmail_refresh()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  k text := secret_key(); rt text; cid text := cfg('gmail_client_id');
  csec text := get_secret('gmail_client_secret'); form text; resp http_response; j jsonb;
BEGIN
  IF k IS NULL OR cid IS NULL OR csec IS NULL THEN RETURN false; END IF;
  SELECT pgp_sym_decrypt(refresh_token, k) INTO rt FROM gmail_auth WHERE refresh_token IS NOT NULL;
  IF rt IS NULL THEN RETURN false; END IF;
  form := 'client_id=' || urlencode(cid)
        || '&client_secret=' || urlencode(csec)
        || '&refresh_token=' || urlencode(rt)
        || '&grant_type=refresh_token';
  resp := almanac_http_post_form('https://oauth2.googleapis.com/token', form);
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN false; END IF;
  j := resp.content::jsonb;
  UPDATE gmail_auth
    SET access_token = pgp_sym_encrypt(j->>'access_token', k),
        expires_at   = now() + ((j->>'expires_in')::int || ' seconds')::interval;
  RETURN true;
END $$;

-- A currently-valid access token (refreshing if needed), or NULL.
CREATE OR REPLACE FUNCTION gmail_access_token()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE k text := secret_key(); exp timestamptz; tok bytea;
BEGIN
  IF k IS NULL THEN RETURN NULL; END IF;
  SELECT expires_at, access_token INTO exp, tok FROM gmail_auth;
  IF tok IS NULL OR exp IS NULL OR exp < now() + interval '60 seconds' THEN
    IF NOT gmail_refresh() THEN RETURN NULL; END IF;
    SELECT access_token INTO tok FROM gmail_auth;
  END IF;
  IF tok IS NULL THEN RETURN NULL; END IF;
  RETURN pgp_sym_decrypt(tok, k);
END $$;

-- Short digest of recent unread mail for a given access token. Reused by both
-- the single-user gmail_fetch() and the per-member team digest (030_team.sql).
CREATE OR REPLACE FUNCTION gmail_unread_digest(p_token text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  hdr jsonb; resp http_response; ids jsonb; mid text;
  subj text; frm text; m jsonb; out text := '';
BEGIN
  IF p_token IS NULL THEN RETURN '(Gmail not connected)'; END IF;
  hdr := jsonb_build_object('Authorization', 'Bearer ' || p_token);
  resp := almanac_http_get(
    'https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=5&q='
    || urlencode('is:unread newer_than:1d'), hdr);
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN '(could not read inbox)'; END IF;
  ids := (resp.content::jsonb)->'messages';
  IF ids IS NULL OR jsonb_array_length(ids) = 0 THEN RETURN 'No unread mail in the last day.'; END IF;

  FOR mid IN SELECT value->>'id' FROM jsonb_array_elements(ids) value LOOP
    resp := almanac_http_get(
      'https://gmail.googleapis.com/gmail/v1/users/me/messages/' || mid ||
      '?format=metadata&metadataHeaders=Subject&metadataHeaders=From', hdr);
    CONTINUE WHEN resp.status NOT BETWEEN 200 AND 299;
    m := resp.content::jsonb;
    SELECT h->>'value' INTO subj FROM jsonb_array_elements(m->'payload'->'headers') h
      WHERE h->>'name' = 'Subject' LIMIT 1;
    SELECT h->>'value' INTO frm FROM jsonb_array_elements(m->'payload'->'headers') h
      WHERE h->>'name' = 'From' LIMIT 1;
    out := out || format(E'- %s — %s\n', COALESCE(subj,'(no subject)'), COALESCE(frm,'?'));
  END LOOP;
  RETURN COALESCE(NULLIF(out,''), 'No unread mail.');
END $$;

-- Single-user inbox digest (the one encrypted gmail_auth token).
CREATE OR REPLACE FUNCTION gmail_fetch()
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  RETURN gmail_unread_digest(gmail_access_token());
END $$;

-- The 7am push: agenda + due todos + inbox digest. Per-step error isolation.
CREATE OR REPLACE FUNCTION daily_summary()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE chat bigint := cfg('owner_chat_id')::bigint; ag text; mail text;
BEGIN
  IF chat IS NULL THEN RETURN; END IF;
  BEGIN ag := execute_tool('agenda', '{}'::jsonb); EXCEPTION WHEN others THEN ag := '(agenda unavailable)'; END;
  BEGIN mail := gmail_fetch(); EXCEPTION WHEN others THEN mail := '(inbox unavailable)'; END;
  PERFORM tg_send(chat, 'Good morning.' || E'\n\n' || ag || E'\n\nInbox:\n' || mail);
END $$;
