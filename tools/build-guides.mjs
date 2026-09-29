// Builds the HTML pages of the site from the Markdown files:
//   docs/guide.md      -> docs/guide/index.html      (https://diskvet.dev/guide/)
//   docs/<xx>/guide.md -> docs/<xx>/guide/index.html (https://diskvet.dev/<xx>/guide/)
//   docs/fix/<slug>.md -> docs/fix/<slug>/index.html (https://diskvet.dev/fix/<slug>/)
// and docs/fix/index.html, the list of the fix pages (https://diskvet.dev/fix/).
// The fix pages are English only. Each one starts with its title (# ...) and a
// <!-- description: ... --> line, which becomes the page's meta description.
// It also points the landing pages' guide links at the guide pages and writes
// docs/sitemap.xml. The Markdown files stay the source; run this after editing
// any of them:
//
//   node tools/build-guides.mjs
//
// Markdown is rendered by GitHub's API (`gh api markdown`), so the pages look
// like the files on GitHub. Needs Node 18+ and a logged-in `gh`.
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
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
const EN = LANGS[0];
const GITHUB_DOCS = 'https://github.com/Protemir/diskvet/blob/main/docs/';
const GITHUB_GUIDE = l => `${GITHUB_DOCS}${l.dir}guide.md`;

// The fix pages, in the order of the list on docs/fix/index.html. A new
// docs/fix/*.md that is missing here goes to the end of the list.
const FIX_ORDER = [
  'clickhouse-trace-log-huge',
  'clickhouse-not-enough-space',
  'clickhouse-max-table-size-to-drop',
  'clickhouse-system-log-copies',
  'clickhouse-system-log-ttl-inside-engine',
  'clickhouse-ttl-delete-not-freeing-disk',
  'clickhouse-too-many-parts',
  'clickhouse-cannot-log-message-ownasyncsplitchannel',
];

const read = p => readFileSync(new URL(p, DOCS), 'utf8');
const write = (p, s) => { mkdirSync(new URL('.', new URL(p, DOCS)), { recursive: true }); writeFileSync(new URL(p, DOCS), s); };
const exists = p => existsSync(new URL(p, DOCS));
const text = html => html.replace(/<[^>]+>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
const attr = s => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
// Relative URL from one site path (a folder, ending in /) to another.
const rel = (from, to) => posix.relative(from, to).replace(/^$/, '.') + '/';

const order = slug => (FIX_ORDER.indexOf(slug) + 1) || FIX_ORDER.length + 1;
const fixSlugs = readdirSync(new URL('fix/', DOCS))
  .filter(f => /^[a-z0-9-]+\.md$/.test(f)).map(f => f.slice(0, -3))
  .sort((a, b) => order(a) - order(b) || (a < b ? -1 : a > b ? 1 : 0));

// The site page of a file in docs/ (a path relative to docs/), or null.
function sitePage(file) {
  let m = file.match(/^(?:([a-z]{2})\/)?guide\.md$/);
  if (m) return m[1] ? `/${m[1]}/guide/` : '/guide/';
  m = file.match(/^fix\/([a-z0-9-]+)\.md$/);
  if (m && fixSlugs.includes(m[1])) return `/fix/${m[1]}/`;
  if (file === 'fix' || file === 'fix/') return '/fix/';
  return null;
}

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
    .replace(/<pre lang="[^"]*">/g, '<pre>')   // ```text
    .replace(/<pre>(?!<code>)([\s\S]*?)<\/pre>/g, (_, code) => `<pre><code>${code}</code></pre>`)
    // Wide tables scroll on phones instead of the whole page.
    .replace(/<table>/g, '<div class="table-scroll"><table>')
    .replace(/<\/table>/g, '</table></div>')
    // Relative links: to the site page if the file has one (the guides, the fix
    // pages), otherwise to the file on GitHub.
    .replace(/href="(?![a-z][a-z0-9+.-]*:|#|\/)([^"#]*)(#[^"]*)?"/g, (_, path, hash = '') => {
      const file = posix.join(posix.dirname(fromMd), path);
      const page = sitePage(file);
      if (page) return `href="${rel(pagePath, page)}${hash}"`;
      if (exists(file)) return `href="${GITHUB_DOCS}${file}${hash}"`;
      throw new Error(`${fromMd}: the link ${path}${hash} goes to no file in docs/`);
    });
}

const landings = Object.fromEntries(LANGS.map(l => [l.code, read(`${l.dir}index.html`)]));
const langOf = l => (landings[l.code].match(/<html lang="([^"]+)"/) || [])[1] || l.hreflang;

// A link on the landing page of language l, for a page at pagePath.
function fromLanding(l, href, pagePath) {
  if (/^(?:[a-z][a-z0-9+.-]*:|#|\/)/.test(href)) return href;
  if (href === 'index.html') return rel(pagePath, `/${l.dir}`);
  const target = posix.join(`/${l.dir}`, href);
  return target.endsWith('/') ? rel(pagePath, target) : posix.relative(pagePath, target);
}

// The parts every page takes from its language's landing page.
function landingParts(l, pagePath) {
  const landing = landings[l.code];
  const pick = re => { const m = landing.match(re); if (!m) throw new Error(`${l.code}: ${re} not found in landing page`); return m; };
  // Locale and link preview image (docs/og.png, from tools/og.svg): the same as the landing page's.
  const shared = [...landing.matchAll(/<meta (?:property="og:(?:locale|image(?::(?:width|height|alt))?)"|name="twitter:card")[^>]*>/g)].map(m => m[0]);
  if (!shared.some(t => t.startsWith('<meta property="og:image"'))) throw new Error(`${l.code}: og:image not found in landing page`);
  const footer = pick(/<footer class="site-footer">[\s\S]*?<\/footer>/)[0]
    .split(`href="${GITHUB_GUIDE(l)}"`).join('href="guide/"')
    .replace(/href="([^"]*)"/g, (_, href) => `href="${fromLanding(l, href, pagePath)}"`);
  return {
    htmlOpen: pick(/<html[^>]*>/)[0],
    icon: pick(/<link rel="icon"[^>]*>/)[0],
    shared,
    skip: pick(/<a class="skip"[^>]*>[\s\S]*?<\/a>/)[0],
    footer,
    navOpen: pick(/<nav aria-label="[^"]*">/)[0],
    navItems: [...pick(/<nav aria-label="[^"]*">\s*<ul>([\s\S]*?)<\/ul>/)[1].matchAll(/<li>[\s\S]*?<\/li>/g)].map(m => m[0].replace(/\s+/g, ' ')),
    globe: pick(/<svg class="globe"[\s\S]*?<\/svg>/)[0],
  };
}

// nav: the main menu's <li> items; menu: the language menu's <li> items.
function layout({ l, pagePath, title, ogTitle, desc, ogType, alternates, nav, menu, content }) {
  const p = landingParts(l, pagePath);
  const url = `${SITE}${pagePath.slice(1)}`;
  return `<!DOCTYPE html>
${p.htmlOpen}
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${attr(title)}</title>
  <meta name="description" content="${attr(desc)}">
  ${p.icon}
  <link rel="stylesheet" href="${rel(pagePath, '/')}style.css">
  <meta property="og:title" content="${attr(ogTitle)}">
  <meta property="og:description" content="${attr(desc)}">
  <meta property="og:url" content="${url}">
  <meta property="og:type" content="${ogType}">
${p.shared.map(t => '  ' + t + '\n').join('')}  <link rel="canonical" href="${url}">
${alternates ? alternates + '\n' : ''}</head>
<body>
${p.skip}

<header class="site-header">
  <div class="wrap">
    <a class="logo" href="${rel(pagePath, `/${l.dir}`)}">diskvet</a>
    <div class="header-right">
      ${p.navOpen}
        <ul>
${nav(p.navItems).map(i => '          ' + i).join('\n')}
        </ul>
      </nav>
      <nav class="langs" aria-label="Language">
        <details>
          <summary>${p.globe} ${l.name}</summary>
          <ul>
${menu.join('\n')}
          </ul>
        </details>
      </nav>
    </div>
  </div>
</header>

<main id="main">
  <div class="wrap narrow">
${content}
  </div>
</main>

${p.footer}
<script src="${rel(pagePath, '/')}langs.js" defer></script>
</body>
</html>
`;
}

const menuItem = (o, href, current) =>
  `            <li><a href="${href}" hreflang="${o.hreflang}" lang="${langOf(o)}"${current ? ' aria-current="page"' : ''}>${o.name}</a></li>`;
// Main menu items for a page that is not one of them.
const plainNav = pagePath => items => items.map(li => li.replace(' aria-current="page"', '')
  .replace(/href="([^"]*)"/, (_, href) => `href="${fromLanding(EN, href, pagePath)}"`));
// The fix pages are English only: English is this page, the other languages go to their guide.
const fixMenu = pagePath => LANGS.map(o => menuItem(o, o === EN ? './' : rel(pagePath, `/${o.dir}guide/`), o === EN));

// Guide pages, one per language.
for (const l of LANGS) {
  const md = read(`${l.dir}guide.md`);
  const pagePath = `/${l.dir}guide/`;
  const body = cleanUp(render(md), `${l.dir}guide.md`, pagePath);

  const isGuide = li => /guide(\.md|\/)"/.test(li);
  const nav = items => items.map(li => {
    li = li.replace(' aria-current="page"', '');
    if (isGuide(li)) return li.replace(/href="[^"]*"/, 'href="./" aria-current="page"');
    return li.replace(/href="([^"]*)"/, (_, href) => `href="${fromLanding(l, href, pagePath)}"`);
  });
  const menu = LANGS.map(o => menuItem(o, rel(pagePath, `/${o.dir}guide/`), o === l));

  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1] || 'diskvet';
  const firstPara = body.replace(/^[\s\S]*?<\/h1>/, '').match(/<p>([\s\S]*?)<\/p>/g) || [];
  const descSource = text((firstPara.find(p => !/guide\/"/.test(p)) || '').replace(/<\/?p>/g, '')).replace(/\s+/g, ' ').trim();
  const desc = descSource.length > 160 ? descSource.slice(0, 157).replace(/\s+\S*$/, '') + '…' : descSource;
  const alternates = LANGS.map(o => `  <link rel="alternate" hreflang="${o.hreflang}" href="${SITE}${o.dir}guide/">`).join('\n')
    + `\n  <link rel="alternate" hreflang="x-default" href="${SITE}guide/">`;

  const page = layout({
    l, pagePath, title: `${text(h1)} · diskvet`, ogTitle: text(h1), desc, ogType: 'article', alternates, nav, menu,
    content: `    <article class="guide">
${body.trim()}
    </article>
    <p class="small muted guide-source"><a href="${GITHUB_GUIDE(l)}">${l.dir ? 'GitHub' : 'Source on GitHub'}</a></p>`,
  });
  write(`${l.dir}guide/index.html`, page);
  console.log(`built /${l.dir}guide/ (${page.length} bytes, ${(body.match(/<h[23] /g) || []).length} headings)`);
}

// Fix pages: one error or symptom each, English only, no hreflang alternates.
const fixes = fixSlugs.map(slug => {
  const fromMd = `fix/${slug}.md`;
  const pagePath = `/fix/${slug}/`;
  const md = read(fromMd);
  const d = md.match(/^<!-- description: (.+?) -->\n/m);
  if (!d) throw new Error(`${fromMd}: no <!-- description: ... --> line`);
  const body = cleanUp(render(md.replace(d[0], '')), fromMd, pagePath);
  const h1 = (body.match(/<h1[^>]*>([\s\S]*?)<\/h1>/) || [])[1];
  if (!h1 || body.split('<h1').length !== 2) throw new Error(`${fromMd}: needs exactly one # title`);
  const title = text(h1).trim();
  const desc = d[1].trim();
  const page = layout({
    l: EN, pagePath, title: `${title} · diskvet`, ogTitle: title, desc, ogType: 'article',
    nav: plainNav(pagePath), menu: fixMenu(pagePath),
    content: `    <article class="guide">
${body.trim()}
    </article>
    <p class="small muted guide-source"><a href="../">All disk errors and fixes</a> · <a href="${GITHUB_DOCS}${fromMd}">Source on GitHub</a></p>`,
  });
  write(`fix/${slug}/index.html`, page);
  console.log(`built /fix/${slug}/ (${page.length} bytes, ${(body.match(/<h[23] /g) || []).length} headings)`);
  return { slug, title, desc };
});

// The list of the fix pages. The titles lose their leading "ClickHouse®" and the
// descriptions their ®: the heading has it.
{
  const pagePath = '/fix/';
  const title = 'Common ClickHouse® disk errors and fixes';
  const list = fixes.map(f => `      <li><a href="${f.slug}/">${attr(f.title.replace(/^ClickHouse®:?\s+/, ''))}</a>
        <p>${attr(f.desc.replace(/ClickHouse®/g, 'ClickHouse'))}</p></li>`).join('\n');
  const page = layout({
    l: EN, pagePath, title: `${title} · diskvet`, ogTitle: title,
    desc: 'One page per ClickHouse® disk error or symptom, such as Code 243, 252 or 359: a read-only check, the fix, and the versions it was tested on.',
    ogType: 'website', nav: plainNav(pagePath), menu: fixMenu(pagePath),
    content: `    <h1>${title}</h1>
    <p>Each page starts from one error message or symptom in self-hosted Langfuse, SigNoz or
      ClickStack. It gives a read-only check, the fix, and the versions it was tested on. For the
      whole picture, from the first check to a TTL that keeps the logs small, read the
      <a href="${rel(pagePath, '/guide/')}">guide</a>.</p>
    <ul class="fix-list">
${list}
    </ul>
    <p class="small muted guide-source"><a href="https://github.com/Protemir/diskvet/tree/main/docs/fix">Source on GitHub</a></p>`,
  });
  write('fix/index.html', page);
  console.log(`built /fix/ (${fixes.length} pages)`);
}

// Landing pages: guide links point at the site pages now.
for (const l of LANGS) {
  const before = landings[l.code];
  const after = before.split(`href="${GITHUB_GUIDE(l)}"`).join('href="guide/"');
  if (after !== before) { write(`${l.dir}index.html`, after); console.log(`landing /${l.dir}: guide links -> guide/`); }
}

// Sitemap: the landing and guide pages with hreflang alternates, then the fix pages.
const group = suffix => LANGS.map(l => `  <url>
    <loc>${SITE}${l.dir}${suffix}</loc>
${LANGS.map(o => `    <xhtml:link rel="alternate" hreflang="${o.hreflang}" href="${SITE}${o.dir}${suffix}"/>`).join('\n')}
    <xhtml:link rel="alternate" hreflang="x-default" href="${SITE}${suffix}"/>
  </url>`).join('\n');
const single = path => `  <url>
    <loc>${SITE}${path}</loc>
  </url>`;
write('sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${group('')}
${group('guide/')}
${[single('fix/'), ...fixes.map(f => single(`fix/${f.slug}/`))].join('\n')}
</urlset>
`);
console.log('wrote sitemap.xml');
