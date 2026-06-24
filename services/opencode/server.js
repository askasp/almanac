// Almanac opencode sidecar. The "hands" Postgres can't have in SQL: a real
// coding agent reachable over HTTP. Postgres' `code` tool POSTs here to start a
// session, then polls; the work runs in the background (sessions take minutes).
//
//   POST /code  { prompt, repo?, branch?, dir? }  -> { job_id }
//   GET  /code/:id  -> { status: running|done|error, result, diff, error }
//   GET  /health
//
// opencode is configured (writeConfig, below) to use the same self-hosted vLLM
// as its model provider, with edit/bash auto-approved so it runs unattended.

const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = process.env.PORT || 5000;
const WORKSPACE = path.resolve(process.env.WORKSPACE_DIR || '/workspace');
const CLONES = '/tmp/clones';

// Write an opencode config that points at our vLLM, built from env at boot so
// the served model id (LLM_MODEL) and endpoint (LLM_BASE_URL) stay a single
// source of truth shared with the db container.
function writeConfig() {
  const baseURL =
    (process.env.LLM_BASE_URL || 'http://host.docker.internal:8000').replace(/\/+$/, '') + '/v1';
  const model = process.env.LLM_MODEL || 'local';
  const apiKey = process.env.LLM_API_KEY || 'not-needed';
  const cfg = {
    $schema: 'https://opencode.ai/config.json',
    provider: {
      vllm: {
        npm: '@ai-sdk/openai-compatible',
        name: 'vLLM (self-hosted)',
        options: { baseURL, apiKey },
        models: { [model]: { name: model } },
      },
    },
    model: `vllm/${model}`,
    // Headless: never block on an interactive permission prompt.
    permission: { edit: 'allow', bash: 'allow', webfetch: 'allow' },
  };
  const out = process.env.OPENCODE_CONFIG || '/app/opencode.json';
  fs.writeFileSync(out, JSON.stringify(cfg, null, 2));
  console.log('opencode config written to ' + out + ' (provider vllm -> ' + baseURL + ')');
}

const jobs = new Map(); // id -> { status, result, diff, error }

function run(cmd, args, cwd) {
  return new Promise((resolve) => {
    let out = '', err = '';
    const p = spawn(cmd, args, { cwd, env: process.env });
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', (e) => resolve({ code: -1, out, err: String((e && e.message) || e) }));
    p.on('close', (code) => resolve({ code, out, err }));
  });
}

async function startJob({ prompt, repo, branch, dir }) {
  const id = crypto.randomBytes(6).toString('hex');
  jobs.set(id, { status: 'running', result: '', diff: '', error: null });
  // Run detached from the request; the caller polls GET /code/:id.
  (async () => {
    const job = jobs.get(id);
    try {
      let cwd = WORKSPACE;
      if (repo) {
        fs.mkdirSync(CLONES, { recursive: true });
        cwd = path.join(CLONES, id);
        const args = ['clone', '--depth', '1'];
        if (branch) args.push('--branch', branch);
        args.push(repo, cwd);
        const c = await run('git', args, CLONES);
        if (c.code !== 0) throw new Error('git clone failed: ' + (c.err || c.out).slice(0, 500));
      } else if (dir) {
        const target = path.resolve(WORKSPACE, dir);
        if (target !== WORKSPACE && !target.startsWith(WORKSPACE + path.sep)) {
          throw new Error('dir escapes the workspace');
        }
        cwd = target;
      }
      const r = await run('opencode', ['run', prompt], cwd);
      const d = await run('git', ['-C', cwd, 'diff'], cwd); // best-effort; empty if not a repo
      job.result = String(r.out || r.err || '').slice(-8000);
      job.diff = String(d.out || '').slice(0, 12000);
      job.status = r.code === 0 ? 'done' : 'error';
      if (r.code !== 0 && !job.error) {
        job.error = String(r.err || 'opencode exited ' + r.code).slice(0, 500);
      }
    } catch (e) {
      job.status = 'error';
      job.error = String((e && e.message) || e);
    }
  })();
  return id;
}

const server = http.createServer((req, res) => {
  const send = (code, obj) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'GET' && req.url === '/health') { res.writeHead(200); return res.end('ok'); }

  const m = req.url.match(/^\/code\/([a-f0-9]+)$/);
  if (req.method === 'GET' && m) {
    const job = jobs.get(m[1]);
    if (!job) return send(404, { error: 'no such job' });
    return send(200, { status: job.status, result: job.result, diff: job.diff, error: job.error });
  }

  if (req.method === 'POST' && req.url === '/code') {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', async () => {
      try {
        const body = JSON.parse(data || '{}');
        if (!body.prompt) return send(400, { error: 'prompt is required' });
        const id = await startJob(body);
        send(200, { job_id: id });
      } catch (e) { send(200, { error: String((e && e.message) || e) }); }
    });
    return;
  }

  res.writeHead(404); res.end('not found');
});

writeConfig();
server.listen(PORT, () => console.log('almanac opencode sidecar listening on ' + PORT));
