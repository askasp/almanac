-- ===========================================================================
-- opencode coding sessions. Same shape as the browser sidecar: the model
-- proposes via the `code` tool, trusted code disposes, the sidecar is the hands.
-- Sessions take minutes, so this is async: `code` starts a job and returns; the
-- code_poll() worker (cron) watches the sidecar and DMs the result + diff.
-- ===========================================================================

CREATE TABLE code_jobs (
  id          bigserial PRIMARY KEY,
  chat_id     bigint,                  -- requester (owner_chat_id at submit time)
  thread_id   bigint,
  prompt      text NOT NULL,
  repo        text,
  dir         text,
  status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running','done','error')),
  job_ref     text,                    -- the sidecar's in-memory job id
  result      text,
  diff        text,
  error       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
CREATE INDEX code_jobs_running_idx ON code_jobs (id) WHERE status = 'running';

-- Start a coding session. Returns immediately; the worker notifies on finish.
CREATE OR REPLACE FUNCTION tool_code(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_prompt text := p_args->>'prompt';
  v_base   text := cfg('opencode_base_url');
  v_chat   bigint := NULLIF(cfg('owner_chat_id'), '')::bigint;
  body jsonb; resp http_response; ref text; jid bigint;
BEGIN
  IF v_prompt IS NULL OR btrim(v_prompt) = '' THEN RETURN 'ERROR: prompt is required'; END IF;
  IF v_base IS NULL OR v_base = '' THEN RETURN 'ERROR: opencode is not configured (opencode_base_url)'; END IF;
  body := jsonb_strip_nulls(jsonb_build_object(
    'prompt', v_prompt,
    'repo',   p_args->>'repo',
    'branch', p_args->>'branch',
    'dir',    p_args->>'dir'));
  resp := almanac_http_post(v_base || '/code', body);
  IF resp.status NOT BETWEEN 200 AND 299 THEN
    RETURN 'ERROR: opencode HTTP ' || COALESCE(resp.status, 0);
  END IF;
  ref := (resp.content::jsonb)->>'job_id';
  IF ref IS NULL THEN
    RETURN 'ERROR: ' || COALESCE((resp.content::jsonb)->>'error', 'opencode did not start a job');
  END IF;
  INSERT INTO code_jobs (chat_id, thread_id, prompt, repo, dir, job_ref)
  VALUES (v_chat, p_thread_id, v_prompt, p_args->>'repo', p_args->>'dir', ref)
  RETURNING id INTO jid;
  RETURN format('🛠️ Started coding job #%s — I''ll message you when it''s done.', jid);
END $$;
SELECT register_tool('code', $$
{"type":"function","function":{"name":"code",
 "description":"Run a coding session with opencode: read and modify code in a project, then report what changed. Use for software tasks (add a feature, fix a bug, refactor, write a script). Runs in the background — the user is messaged with the result and a diff when it finishes. Works on the mounted /workspace by default; pass repo to clone a git URL first, or dir for a subfolder of the workspace.",
 "parameters":{"type":"object","properties":{
   "prompt":{"type":"string","description":"What to do, in plain language"},
   "repo":{"type":"string","description":"Optional git URL to clone and work in"},
   "branch":{"type":"string","description":"Optional branch to clone"},
   "dir":{"type":"string","description":"Optional subfolder of the workspace to work in"}},
   "required":["prompt"]}}}$$::jsonb, 70);

-- Poll running jobs; on completion store the outcome and DM the requester.
-- (cron: almanac-code, ~20s)
CREATE OR REPLACE FUNCTION code_poll()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  j record; resp http_response; r jsonb; st text; msg text;
  v_base text := cfg('opencode_base_url'); cnt int := 0;
BEGIN
  IF v_base IS NULL OR v_base = '' THEN RETURN 0; END IF;
  FOR j IN SELECT * FROM code_jobs WHERE status = 'running' ORDER BY id LIMIT 10 LOOP
    BEGIN
      resp := almanac_http_get(v_base || '/code/' || j.job_ref);
      CONTINUE WHEN resp.status NOT BETWEEN 200 AND 299;
      r  := resp.content::jsonb;
      st := COALESCE(r->>'status', 'running');
      CONTINUE WHEN st = 'running';

      UPDATE code_jobs
        SET status = st, result = r->>'result', diff = r->>'diff',
            error = r->>'error', finished_at = now()
        WHERE id = j.id;

      IF j.chat_id IS NOT NULL THEN
        msg := CASE WHEN st = 'done'
                    THEN '✅ Coding job #' || j.id || ' done.'
                    ELSE '⚠️ Coding job #' || j.id || ' failed: ' || COALESCE(r->>'error', '?') END;
        IF COALESCE(r->>'result', '') <> '' THEN msg := msg || E'\n\n' || left(r->>'result', 1500); END IF;
        IF COALESCE(r->>'diff', '')   <> '' THEN msg := msg || E'\n\n--- diff ---\n' || left(r->>'diff', 2000); END IF;
        PERFORM tg_send(j.chat_id, msg);
      END IF;
      cnt := cnt + 1;
    EXCEPTION WHEN others THEN
      NULL;  -- transient sidecar error: leave running, retry next tick
    END;
  END LOOP;
  RETURN cnt;
END $$;
