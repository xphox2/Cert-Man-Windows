/*
 * Build the training deck PDF from deck.html using the headless Chromium that
 * ships with mermaid-cli (puppeteer). One ordered slide per diagram.
 *
 * Prereq:  npm install -g @mermaid-js/mermaid-cli
 * Run:     node build-deck.js
 * Output:  SSL-Cert-Rotation-Training-Deck.pdf  (this folder)
 */
const path = require('path');

function resolvePuppeteer() {
  const candidates = [
    'puppeteer',
    path.join(process.env.APPDATA || '', 'npm', 'node_modules', '@mermaid-js', 'mermaid-cli', 'node_modules', 'puppeteer'),
  ];
  for (const c of candidates) {
    try { return require(c); } catch (_) { /* try next */ }
  }
  throw new Error('puppeteer not found. Install mermaid-cli:  npm install -g @mermaid-js/mermaid-cli');
}

(async () => {
  const puppeteer = resolvePuppeteer();
  const htmlPath = path.join(__dirname, 'deck.html');
  const outPath = path.join(__dirname, 'SSL-Cert-Rotation-Training-Deck.pdf');
  const fileUrl = 'file:///' + htmlPath.replace(/\\/g, '/');

  const browser = await puppeteer.launch({ headless: 'new', args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    await page.goto(fileUrl, { waitUntil: 'networkidle0' });
    await page.pdf({
      path: outPath,
      landscape: true,
      printBackground: true,
      preferCSSPageSize: true,
      margin: { top: 0, right: 0, bottom: 0, left: 0 },
    });
    console.log('Wrote ' + outPath);
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
