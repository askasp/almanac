#!/usr/bin/env node
// One-time Gmail consent. This is the ONLY non-Postgres piece of the runtime
// path, and it runs exactly once. It gets a refresh token and stores it
// (encrypted) by calling gmail_set_refresh() in the database.
//
// Prereqs: a Google Cloud OAuth "Desktop app" client. Put its id/secret in
// your .env (GMAIL_CLIENT_ID / GMAIL_CLIENT_SECRET), then:
//
//   docker compose up -d db
//   GMAIL_CLIENT_ID=... GMAIL_CLIENT_SECRET=... node scripts/oauth.mjs
//
// Open the printed URL, approve, and it stores the token. Uses only Node
// built-ins (no npm install).

import http from 'node:http';
import https from 'node:https';
import { spawnSync } from 'node:child_process';

const CLIENT_ID = process.env.GMAIL_CLIENT_ID;
const CLIENT_SECRET = process.env.GMAIL_CLIENT_SECRET;
const PORT = 53682;
const REDIRECT = `http://localhost:${PORT}/`;
const SCOPE = 'https://www.googleapis.com/auth/gmail.readonly';

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error('Set GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET in the environment.');
  process.exit(1);
}

function postForm(url, form) {
  const body = new URLSearchParams(form).toString();
  return new Promise((resolve, reject) => {
    const req = https.request(
      url,
      { method: 'POST', headers: {
        'content-type': 'application/x-www-form-urlencoded',
        'content-length': Buffer.byteLength(body),
      } },
      (res) => {
        let d = '';
        res.on('data', (c) => (d += c));
        res.on('end', () => resolve(JSON.parse(d)));
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function storeRefreshToken(token) {
  // Store via the running db container (encrypted by gmail_set_refresh()).
  const user = process.env.POSTGRES_USER || 'almanac';
  const db = process.env.POSTGRES_DB || 'almanac';
  const sql = `SELECT gmail_set_refresh($tok$${token}$tok$);`;
  const r = spawnSync(
    'docker',
    ['compose', 'exec', '-T', 'db', 'psql', '-U', user, '-d', db, '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { stdio: 'inherit' }
  );
  if (r.status !== 0) {
    console.log('\nCould not auto-store. Run this manually:\n');
    console.log(`docker compose exec -T db psql -U ${user} -d ${db} -c "SELECT gmail_set_refresh('${token}')"`);
  } else {
    console.log('\n✅ Gmail refresh token stored. The daily summary can now read your inbox.');
  }
}

const authUrl =
  'https://accounts.google.com/o/oauth2/v2/auth?' +
  new URLSearchParams({
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT,
    response_type: 'code',
    scope: SCOPE,
    access_type: 'offline',
    prompt: 'consent',
  }).toString();

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, REDIRECT);
  const code = u.searchParams.get('code');
  if (!code) { res.writeHead(400); return res.end('no code'); }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('Almanac: Gmail connected. You can close this tab.');
  server.close();
  try {
    const tok = await postForm('https://oauth2.googleapis.com/token', {
      code, client_id: CLIENT_ID, client_secret: CLIENT_SECRET,
      redirect_uri: REDIRECT, grant_type: 'authorization_code',
    });
    if (!tok.refresh_token) {
      console.error('No refresh_token returned. Revoke prior access and retry with prompt=consent.');
      console.error(tok);
      process.exit(1);
    }
    storeRefreshToken(tok.refresh_token);
    process.exit(0);
  } catch (e) {
    console.error('Token exchange failed:', e);
    process.exit(1);
  }
});

server.listen(PORT, () => {
  console.log('\nOpen this URL to authorize Gmail access:\n\n' + authUrl + '\n');
});
