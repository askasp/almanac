-- ===========================================================================
-- GitHub: recent commits on a branch. One outbound API call via pgsql-http; the
-- model (in chat) or a pipeline's `ai` step turns the list into a summary.
-- The `github_token` secret is OPTIONAL: public repos work unauthenticated (rate
-- limited to ~60 req/hr); set it for private repos and higher limits. GitHub
-- requires a User-Agent header, which we always send. owner/repo/branch are
-- url-encoded into a fixed api.github.com path (no SSRF surface — no user URLs).
-- ===========================================================================

CREATE OR REPLACE FUNCTION github_commits_digest(p_owner text, p_repo text, p_branch text, p_days int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  tok  text := get_secret('github_token');
  hdr  jsonb; url text; resp http_response; arr jsonb; c jsonb; out text := ''; n int := 0;
  since text := to_char((now() - make_interval(days => GREATEST(p_days, 1))) AT TIME ZONE 'UTC',
                        'YYYY-MM-DD"T"HH24:MI:SS"Z"');
BEGIN
  hdr := jsonb_build_object('User-Agent', 'almanac', 'Accept', 'application/vnd.github+json');
  IF tok IS NOT NULL THEN hdr := hdr || jsonb_build_object('Authorization', 'Bearer ' || tok); END IF;
  url := format('https://api.github.com/repos/%s/%s/commits?sha=%s&since=%s&per_page=100',
                urlencode(p_owner), urlencode(p_repo), urlencode(p_branch), urlencode(since));
  resp := almanac_http_get(url, hdr);
  IF resp.status = 404 THEN
    RETURN format('(not found: %s/%s @ %s — check the owner, repo and branch)', p_owner, p_repo, p_branch);
  END IF;
  IF resp.status IN (401, 403) THEN
    RETURN format('(GitHub denied the request, status %s — a private repo needs the github_token secret, or you hit the rate limit)', resp.status);
  END IF;
  IF resp.status NOT BETWEEN 200 AND 299 THEN RETURN format('(GitHub error %s)', resp.status); END IF;
  arr := resp.content::jsonb;
  IF jsonb_typeof(arr) <> 'array' OR jsonb_array_length(arr) = 0 THEN
    RETURN format('No commits on %s in %s/%s in the last %s day(s).', p_branch, p_owner, p_repo, p_days);
  END IF;
  FOR c IN SELECT value FROM jsonb_array_elements(arr) LOOP
    out := out || format(E'- %s  %s  (%s, %s)\n',
             substr(c->>'sha', 1, 7),
             split_part(c->'commit'->>'message', E'\n', 1),         -- first line only
             COALESCE(c->'author'->>'login', c->'commit'->'author'->>'name', '?'),
             substr(c->'commit'->'author'->>'date', 1, 10));
    n := n + 1;
  END LOOP;
  RETURN format(E'%s commit(s) on %s in %s/%s (last %s day(s)):\n%s',
                n, p_branch, p_owner, p_repo, p_days, btrim(out, E'\n'));
END $$;

CREATE OR REPLACE FUNCTION tool_github_commits(p_args jsonb, p_thread_id bigint, p_run_id bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_owner  text := btrim(COALESCE(p_args->>'owner', ''));
  v_repo   text := btrim(COALESCE(p_args->>'repo', ''));
  v_branch text := COALESCE(NULLIF(btrim(p_args->>'branch'), ''), 'main');
  v_days   int  := LEAST(GREATEST(COALESCE((p_args->>'days')::int, 7), 1), 90);
BEGIN
  IF v_owner = '' OR v_repo = '' THEN RETURN 'ERROR: owner and repo are required'; END IF;
  RETURN github_commits_digest(v_owner, v_repo, v_branch, v_days);
END $$;
SELECT register_tool('github_commits', $$
{"type":"function","function":{"name":"github_commits",
 "description":"List recent commits on a branch of a GitHub repo (branch defaults to main, window defaults to the last 7 days, max 100 commits). Returns one line per commit (short sha, summary, author, date) for you to summarize. Public repos work without setup; private repos need the github_token secret.",
 "parameters":{"type":"object","properties":{
   "owner":{"type":"string","description":"repo owner or org, e.g. askasp"},
   "repo":{"type":"string","description":"repository name, e.g. almanac"},
   "branch":{"type":"string","description":"branch name (default main)"},
   "days":{"type":"integer","description":"how many days back to include (default 7, max 90)"}},
   "required":["owner","repo"]}}}$$::jsonb, 53);
