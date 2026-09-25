// Builds the guide pages of the site from the Markdown guides:
//   docs/guide.md      -> docs/guide/index.html      (https://diskvet.dev/guide/)
//   docs/<xx>/guide.md -> docs/<xx>/guide/index.html (https://diskvet.dev/<xx>/guide/)
// It also points the landing pages' guide links at those pages and writes
// docs/sitemap.xml. The Markdown files stay the source; run this after editing
// any of them:
//
//   node tools/build-guides.mjs
//
// Markdown is rendered by GitHub's API (`gh api markdown`), so the pages look
// like the files on GitHub. Needs Node 18+ and a logged-in `gh`.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { posix } from 'node:path';

const DOCS = new URL('../docs/', import.meta.url);
const SITE = 'https://diskvet.dev/';
const LANGS = [
  { code: 'en', dir: '', hreflang: 'en', name: 'English' },
  { code: 'es', dir: 'es/', hreflang: 'es', name: 'Español' },
  { code: 'pt', dir: 'pt/', hreflang: 'pt', name: 'Português' },
  { code: 'ru', dir: 'ru/', hreflang: 'ru', name: 'Русский' },
  { code: 'ja', dir: 'ja/', hreflang: 'ja', name: '日本語' },
  { code: 'ko', dir: 'ko/', hreflang: 'ko', name: '한국어' },
  { code: 'zh', dir: 'zh/', hreflang: 'zh-Hans', name: '中文' },
];
const GITHUB_GUIDE = l => `https://github.com/Protemir/diskvet/blob/main/docs/${l.dir}guide.md`;

const read = p => readFileSync(new URL(p, DOCS), 'utf8');
const write = (p, s) => { mkdirSync(new URL('.', new URL(p, DOCS)), { recursive: true }); writeFileSync(new URL(p, DOCS), s); };
const text = html => html.replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
const attr = s => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
// Relative URL from one site path (a folder, ending in /) to another.
const rel = (from, to) => posix.relative(from, to).replace(/^$/, '.') + '/';

function render(markdown) {
  // mode 'markdown' renders like a file on GitHub; 'gfm' would turn every line break into <br>.
  const input = JSON.stringify({ text: markdown, mode: 'markdown' });
  return execFileSync('gh', ['api', 'markdown', '--input', '-'], { input, encoding: 'utf8', maxBuffer: 16 << 20 });
}

function cleanUp(html, fromMd, pagePath) {
  return html
    // Headings: keep GitHub's own ids (the same anchors as the .md files on GitHub),
    // without its wrapper, permalink icon and "user-content-" prefix.
    .replace(/<div class="markdown-heading"><h([1-6]) class="heading-element">([\s\S]*?)<\/h\1><a id="user-content-([^"]+)" class="anchor"[^>]*>[\s\S]*?<\/a><\/div>/g,
      (_, n, inner, id) => `<h${n} id="${id}">${inner}</h${n}>`)
    .replace(/ dir="auto"/g, '')
    .replace(/ class="notranslate"/g, '')
    .replace(/ rel="nofollow"/g, '')
    // Code blocks: plain <pre><code>, without GitHub's highlighting spans.
    .replace(/<div class="highlight[^"]*"><pre>([\s\S]*?)<\/pre><\/div>/g,
      (_, code) => `<pre><code>${code.replace(/<\/?span[^>]*>/g, '')}</code></pre>`)
    .replace(/<pre>(?!<code>)([\s\S]*?)<\/pre>/g, (_, code) => `<pre><code>${code}</code></pre>`)
    // Links between the Markdown guides become links between the guide pages.
    .replace(/href="((?:\.\.\/)?(?:[a-z]{2}\/)?guide\.md)"/g, (_, href) => {
      const dir = posix.dirname(posix.join(posix.dirname(fromMd), href));   // '.' or 'ru'
      return `href="${rel(pagePath, dir === '.' ? '/guide/' : `/${dir}/guide/`)}"`;
    });
}

const landings = Object.fromEntries(LANGS.map(l => [l.code, read(`${l.dir}index.html`)]));
const langOf = l => (landings[l.code].match(/<html lang="([^"]+)"/) || [])[1] || l.hreflang;

for (const l of LANGS) {
  const md = read(`${l.dir}guide.md`);
  const pagePath = `/${l.dir}guide/`;
  const body = cleanUp(render(md), `${l.dir}guide.md`, pagePath);
  const landing = landings[l.code];
  const pick = re => { const m = landing.match(re); if (!m) throw new Error(`${l.code}: ${re} not found in landing page`); return m; };

  const htmlOpen = pick(/<html[^>]*>/)[0];
  const icon = pick(/<link rel="icon"[^>]*>/)[0];
  const locale = (landing.match(/<meta property="og:locale"[^>]*>/) || [''])[0];
  const skip = pick(/<a class="skip"[^>]*>[\s\S]*?<\/a>/)[0];
  const footer = pick(/<footer class="site-footer">[\s\S]*?<\/footer>/)[0];
  const navOpen = pick(/<nav aria-label="[^"]*">/)[0];
  const navItems = [...pick(/<nav aria-label="[^"]*">\s*<ul>([\s\S]*?)<\/ul>/)[1].matchAll(/<li>[\s\S]*?<\/li>/g)].map(m => m[0].replace(/\s+/g, ' '));
  const toLanding = rel(pagePath, `/${l.dir}`);

  const isGuide = li => /guide(\.md|\/)"/.test(li);
  const nav = navItems.map(li => {
    li = li.replace(' aria-current="page"', '');
    if (isGuide(li)) return li.replace(/href="[^"]*"/, 'href="./" aria-current="page"');
    return li.replace(/href="index\.html"/, `href="${toLanding}"`);
  });
  const menu = LANGS.map(o => {
    const cur = o.code === l.code ? ' aria-current="page"' : '';
    return `            <li><a href="${rel(pagePath, `/${o.dir}guide/`)}" hreflang="${o.hreflang}" lang="${langOf(o)}"${cur}>${o.name}</a></li>`;
  }).join('\n');
  const globe = pick(/<svg class="globe"[\s\S]*?<\/svg>/)[0];

  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1] || 'diskvet';
  const firstPara = body.replace(/^[\s\S]*?<\/h1>/, '').match(/<p>([\s\S]*?)<\/p>/g) || [];
  const descSource = text((firstPara.find(p => !/guide\/"/.test(p)) || '').replace(/<\/?p>/g, '')).replace(/\s+/g, ' ').trim();
  const desc = descSource.length > 160 ? descSource.slice(0, 157).replace(/\s+\S*$/, '') + '…' : descSource;
  const url = `${SITE}${l.dir}guide/`;
  const alternates = LANGS.map(o => `  <link rel="alternate" hreflang="${o.hreflang}" href="${SITE}${o.dir}guide/">`).join('\n')
    + `\n  <link rel="alternate" hreflang="x-default" href="${SITE}guide/">`;

  const page = `<!DOCTYPE html>
${htmlOpen}
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${attr(text(h1))} · diskvet</title>
  <meta name="description" content="${attr(desc)}">
  ${icon}
  <link rel="stylesheet" href="${rel(pagePath, '/')}style.css">
  <meta property="og:title" content="${attr(text(h1))}">
  <meta property="og:description" content="${attr(desc)}">
  <meta property="og:url" content="${url}">
  <meta property="og:type" content="article">
${locale ? '  ' + locale + '\n' : ''}  <link rel="canonical" href="${url}">
${alternates}
</head>
<body>
${skip}

<header class="site-header">
  <div class="wrap">
    <a class="logo" href="${toLanding}">diskvet</a>
    <div class="header-right">
      ${navOpen}
        <ul>
${nav.map(i => '          ' + i).join('\n')}
        </ul>
      </nav>
      <nav class="langs" aria-label="Language">
        <details>
          <summary>${globe} ${l.name}</summary>
          <ul>
${menu}
          </ul>
        </details>
      </nav>
    </div>
  </div>
</header>

<main id="main">
  <div class="wrap narrow">
    <article class="guide">
${body.trim()}
    </article>
    <p class="small muted guide-source"><a href="${GITHUB_GUIDE(l)}">${l.dir ? 'GitHub' : 'Source on GitHub'}</a></p>
  </div>
</main>

${footer.replace(/href="https:\/\/github\.com\/Protemir\/diskvet\/blob\/main\/docs\/(?:[a-z]{2}\/)?guide\.md"/g, 'href="./"').replace(/href="guide\/"/g, 'href="./"')}
<script src="${rel(pagePath, '/')}langs.js" defer></script>
</body>
</html>
`;
  write(`${l.dir}guide/index.html`, page);
  console.log(`built /${l.dir}guide/ (${page.length} bytes, ${(body.match(/<h[23] /g) || []).length} headings)`);
}

// Landing pages: guide links point at the site pages now.
for (const l of LANGS) {
  const before = landings[l.code];
  const after = before.split(`href="${GITHUB_GUIDE(l)}"`).join('href="guide/"');
  if (after !== before) { write(`${l.dir}index.html`, after); console.log(`landing /${l.dir}: guide links -> guide/`); }
}

// Sitemap with hreflang alternates for both page groups.
const group = suffix => LANGS.map(l => `  <url>
    <loc>${SITE}${l.dir}${suffix}</loc>
${LANGS.map(o => `    <xhtml:link rel="alternate" hreflang="${o.hreflang}" href="${SITE}${o.dir}${suffix}"/>`).join('\n')}
    <xhtml:link rel="alternate" hreflang="x-default" href="${SITE}${suffix}"/>
  </url>`).join('\n');
write('sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${group('')}
${group('guide/')}
</urlset>
`);
console.log('wrote sitemap.xml');
