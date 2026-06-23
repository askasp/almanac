-- ===========================================================================
-- Secrets at rest (pgcrypto). The symmetric key is NEVER stored in the table;
-- it comes from the GUC almanac.secret_key, applied per-database by the
-- bootstrap script (ALTER DATABASE ... SET almanac.secret_key = '<env>').
-- Encryption protects stolen backups/disk, not a live-host compromise.
-- ===========================================================================

CREATE TABLE secrets (
  name  text PRIMARY KEY,
  value bytea NOT NULL          -- pgp_sym_encrypt(plaintext, key)
);

CREATE OR REPLACE FUNCTION secret_key() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('almanac.secret_key', true), '')
$$;

-- Store/replace a secret. SECURITY DEFINER so only this trusted code touches
-- the key; callers never pass it around.
CREATE OR REPLACE FUNCTION set_secret(p_name text, p_value text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE k text := secret_key();
BEGIN
  IF k IS NULL THEN
    RAISE EXCEPTION 'almanac.secret_key is not set; cannot store secrets';
  END IF;
  INSERT INTO secrets (name, value)
  VALUES (p_name, pgp_sym_encrypt(p_value, k))
  ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
END $$;

-- Returns NULL if the secret is absent (callers guard on this).
CREATE OR REPLACE FUNCTION get_secret(p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE k text := secret_key(); v bytea;
BEGIN
  IF k IS NULL THEN RETURN NULL; END IF;
  SELECT value INTO v FROM secrets WHERE name = p_name;
  IF v IS NULL THEN RETURN NULL; END IF;
  RETURN pgp_sym_decrypt(v, k);
END $$;

-- Small config helpers (non-secret).
CREATE OR REPLACE FUNCTION cfg(p_key text, p_default text DEFAULT NULL)
RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT value FROM config WHERE key = p_key), p_default)
$$;

CREATE OR REPLACE FUNCTION set_cfg(p_key text, p_value text)
RETURNS void
LANGUAGE sql AS $$
  INSERT INTO config (key, value) VALUES (p_key, p_value)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
$$;
