-- ===========================================================================
-- Almanac core schema. Plain relational tables (intentionally not event-sourced).
-- The embedding column is vector(1024); pick a 1024-dim embedding model
-- (bge-large-en-v1.5, e5-large, Qwen3-Embedding-0.6B, ...) or edit this one line.
-- ===========================================================================

-- Conversations -------------------------------------------------------------
CREATE TABLE threads (
  id              bigserial PRIMARY KEY,
  slug            text UNIQUE,                      -- short tag, e.g. 'a3f'
  title           text,
  status          text NOT NULL DEFAULT 'active',   -- active | archived
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX threads_recent_idx ON threads (last_message_at DESC);

CREATE TABLE messages (
  id                     bigserial PRIMARY KEY,
  thread_id              bigint REFERENCES threads(id) ON DELETE CASCADE,
  role                   text NOT NULL CHECK (role IN ('user','assistant')),
  content                text,
  blocks                 jsonb,        -- full OpenAI message object (for replay)
  status                 text NOT NULL DEFAULT 'done'
                            CHECK (status IN ('pending','processing','done','error')),
  tg_chat_id             bigint,
  tg_message_id          bigint,
  reply_to_tg_message_id bigint,
  attempts               int NOT NULL DEFAULT 0,
  error                  text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  processed_at           timestamptz
);
-- The worker only ever claims inbound user rows that are pending.
CREATE INDEX messages_pending_idx ON messages (id)
  WHERE role = 'user' AND status = 'pending';
CREATE INDEX messages_thread_idx ON messages (thread_id, id);
CREATE INDEX messages_tg_idx ON messages (tg_message_id);

-- Almanac data --------------------------------------------------------------
CREATE TABLE todos (
  id         bigserial PRIMARY KEY,
  title      text NOT NULL,
  due        timestamptz,
  done       boolean NOT NULL DEFAULT false,
  done_at    timestamptz,
  notes      text,
  thread_id  bigint REFERENCES threads(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX todos_open_idx ON todos (due) WHERE NOT done;

CREATE TABLE calendar (
  id         bigserial PRIMARY KEY,
  title      text NOT NULL,
  starts_at  timestamptz NOT NULL,
  ends_at    timestamptz,
  location   text,
  notes      text,
  thread_id  bigint REFERENCES threads(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX calendar_starts_idx ON calendar (starts_at);

CREATE TABLE items (
  id         bigserial PRIMARY KEY,
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX items_name_idx ON items (lower(name));

CREATE TABLE item_locations (
  id        bigserial PRIMARY KEY,
  item_id   bigint NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  location  text NOT NULL,
  note      text,
  noted_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX item_locations_latest_idx ON item_locations (item_id, noted_at DESC);

CREATE TABLE notes (
  id         bigserial PRIMARY KEY,
  body       text NOT NULL,
  tags       text[],
  thread_id  bigint REFERENCES threads(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  embedding  vector(1024)              -- NULL until kb_ingest() fills it
);
-- ivfflat needs rows before it helps; safe to create empty.
CREATE INDEX notes_embedding_idx ON notes
  USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- Extensibility layer -------------------------------------------------------
CREATE TABLE pipelines (
  id          bigserial PRIMARY KEY,
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  description text,
  enabled     boolean NOT NULL DEFAULT true,
  cron_expr   text,                    -- set => scheduled via pg_cron
  created_by  text NOT NULL DEFAULT 'user' CHECK (created_by IN ('user','ai')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pipeline_steps (
  id          bigserial PRIMARY KEY,
  pipeline_id bigint NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE,
  ordinal     int NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('tool','ai','notify')),
  name        text,
  config      jsonb NOT NULL DEFAULT '{}',   -- tool+args template / ai prompt / etc.
  UNIQUE (pipeline_id, ordinal)
);

CREATE TABLE pipeline_runs (
  id          bigserial PRIMARY KEY,
  pipeline_id bigint NOT NULL REFERENCES pipelines(id) ON DELETE CASCADE,
  status      text NOT NULL DEFAULT 'running'
                CHECK (status IN ('running','done','error')),
  trigger     text NOT NULL DEFAULT 'manual'
                CHECK (trigger IN ('manual','cron','chat')),
  context     jsonb NOT NULL DEFAULT '{}',   -- accumulates {step_N: output}
  result      jsonb,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  error       text
);
CREATE INDEX pipeline_runs_pipeline_idx ON pipeline_runs (pipeline_id, started_at DESC);

CREATE TABLE pipeline_run_steps (
  id          bigserial PRIMARY KEY,
  run_id      bigint NOT NULL REFERENCES pipeline_runs(id) ON DELETE CASCADE,
  step_id     bigint REFERENCES pipeline_steps(id) ON DELETE SET NULL,
  ordinal     int NOT NULL,
  status      text NOT NULL DEFAULT 'running'
                CHECK (status IN ('running','done','error')),
  input       jsonb,
  output      jsonb,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  error       text
);
CREATE INDEX pipeline_run_steps_run_idx ON pipeline_run_steps (run_id, ordinal);

-- Audit of every tool call (from chat or pipelines) -------------------------
CREATE TABLE actions (
  id         bigserial PRIMARY KEY,
  thread_id  bigint,
  run_id     bigint,
  tool_name  text NOT NULL,
  input      jsonb,
  result     text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Operational state ---------------------------------------------------------
CREATE TABLE tg_state (
  id             boolean PRIMARY KEY DEFAULT true CHECK (id),
  last_update_id bigint NOT NULL DEFAULT 0
);
INSERT INTO tg_state (id) VALUES (true);

CREATE TABLE config (
  key   text PRIMARY KEY,
  value text
);

CREATE TABLE gmail_auth (
  id            boolean PRIMARY KEY DEFAULT true CHECK (id),
  access_token  bytea,
  refresh_token bytea,
  expires_at    timestamptz
);
INSERT INTO gmail_auth (id) VALUES (true);
