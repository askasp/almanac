// Almanac browser sidecar. The "hands" Postgres can't have in SQL: a real
// headless Chromium reachable over HTTP. Postgres' browse tool POSTs here.
//
//   POST /browse  { url, actions?, extract? }
//     actions: [{type:"click|fill|wait|waitForSelector", selector?, value?, ms?}]
//     extract: optional CSS selector (returns its text instead of the whole page)
//   -> { title, url, text }  on success, { error } on failure
//
// One Chromium instance is reused; each request gets a fresh context.

const http = require('http');
const { chromium } = require('playwright');

const UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0 Safari/537.36';

let browserPromise = null;
function getBrowser() {
  if (!browserPromise) browserPromise = chromium.launch({ args: ['--no-sandbox'] });
  return browserPromise;
}

async function browse({ url, actions = [], extract }) {
  if (!url) return { error: 'url is required' };
  const browser = await getBrowser();
  const ctx = await browser.newContext({ userAgent: UA });
  const page = await ctx.newPage();
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    for (const a of Array.isArray(actions) ? actions : []) {
      if (a.type === 'click') await page.click(a.selector, { timeout: 10000 });
      else if (a.type === 'fill') await page.fill(a.selector, a.value || '', { timeout: 10000 });
      else if (a.type === 'waitForSelector') await page.waitForSelector(a.selector, { timeout: 15000 });
      else if (a.type === 'wait') await page.waitForTimeout(Math.min(Number(a.ms) || 1000, 15000));
    }
    const title = await page.title();
    let text;
    if (extract) text = (await page.locator(extract).allInnerTexts()).join('\n');
    else text = await page.evaluate(() => (document.body ? document.body.innerText : ''));
    return { title, url: page.url(), text: String(text || '').slice(0, 20000) };
  } finally {
    await ctx.close().catch(() => {});
  }
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200); return res.end('ok');
  }
  if (req.method === 'POST' && req.url === '/browse') {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', async () => {
      let out;
      try { out = await browse(JSON.parse(data || '{}')); }
      catch (e) { out = { error: String((e && e.message) || e) }; }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(out));
    });
    return;
  }
  res.writeHead(404); res.end('not found');
});

const port = process.env.PORT || 3000;
server.listen(port, () => console.log('almanac browser sidecar listening on ' + port));
