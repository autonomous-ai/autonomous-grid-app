/// The JavaScript the app injects to read a page the way an agent needs it.
///
/// An **accessibility snapshot**, not the HTML: a tree of roles and names with
/// a `ref` on everything worth acting on. Raw HTML is the obvious alternative
/// and the wrong one — a modern page is tens of thousands of tokens of wrapper
/// divs and inlined CSS, and the model has to guess a CSS selector out of it
/// that breaks on the next deploy. A ref names *the element this snapshot saw*,
/// so a click is unambiguous or it fails loudly.
///
/// The refs live in `window.__gridRefs` for the lifetime of the document. A
/// navigation clears them, which is the honest behaviour: a ref from the page
/// you were on before means nothing here, and the agent is told to snapshot
/// again rather than clicking whatever happens to be in that slot now.
library;

/// Builds the page's snapshot and returns it as a JSON string.
///
/// A string rather than an object: what an engine marshals back from
/// `evaluateJavascript` differs by platform and by nesting depth, and a string
/// is the one shape both WKWebView and WebView2 return unchanged.
const String kBrowserSnapshotScript = r'''
(() => {
  const MAX_NODES = 500;
  const MAX_NAME = 120;
  const refs = new Map();
  window.__gridRefs = refs;
  let seq = 0;
  let nodes = 0;
  let truncated = false;

  const clean = (value) =>
    (value || '').replace(/\s+/g, ' ').trim().slice(0, MAX_NAME);

  // Roles that hold other roles. Their name is whatever the page *says* it is
  // and never their text: measured on duckduckgo.com, letting `main` fall back
  // to innerText put the whole page — nav, footer and all — on the first line
  // of the snapshot as one 120-character name.
  const CONTAINERS = new Set([
    'main', 'navigation', 'banner', 'contentinfo', 'form', 'search', 'region',
    'complementary', 'article', 'group', 'radiogroup', 'tablist', 'menu',
    'menubar', 'toolbar', 'table', 'list', 'listitem', 'dialog', 'grid',
    'rowgroup', 'row', 'tabpanel', 'none', 'presentation'
  ]);

  const roleOf = (el) => {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit.trim();
    const tag = el.tagName.toLowerCase();
    if (tag === 'a') return el.hasAttribute('href') ? 'link' : null;
    if (tag === 'button') return 'button';
    if (tag === 'select') return 'combobox';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'img') return 'image';
    if (tag === 'table') return 'table';
    if (tag === 'form') return 'form';
    if (tag === 'nav') return 'navigation';
    if (tag === 'main') return 'main';
    if (tag === 'header') return 'banner';
    if (tag === 'footer') return 'contentinfo';
    if (/^h[1-6]$/.test(tag)) return 'heading';
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      if (type === 'submit' || type === 'button' || type === 'reset') {
        return 'button';
      }
      if (type === 'hidden') return null;
      return 'textbox';
    }
    return null;
  };

  const nameOf = (el, role) => {
    const aria = el.getAttribute('aria-label');
    if (aria) return clean(aria);
    const by = el.getAttribute('aria-labelledby');
    if (by) {
      const labelled = by
        .split(/\s+/)
        .map((id) => document.getElementById(id))
        .filter(Boolean)
        .map((node) => node.textContent)
        .join(' ');
      if (labelled.trim()) return clean(labelled);
    }
    if (el.tagName === 'IMG') return clean(el.getAttribute('alt'));
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      const labelled = el.labels && el.labels.length
        ? el.labels[0].textContent
        : '';
      return clean(
        labelled ||
          el.getAttribute('placeholder') ||
          el.getAttribute('name') ||
          el.getAttribute('title')
      );
    }
    if (CONTAINERS.has(role)) return '';
    if (role === 'combobox') {
      const chosen = el.options && el.selectedIndex >= 0
        ? el.options[el.selectedIndex].textContent
        : '';
      return clean(el.getAttribute('name') || chosen);
    }
    return clean(el.innerText || el.textContent);
  };

  const actionable = (el, role) =>
    role === 'link' ||
    role === 'button' ||
    role === 'textbox' ||
    role === 'checkbox' ||
    role === 'radio' ||
    role === 'combobox' ||
    el.hasAttribute('onclick') ||
    el.getAttribute('contenteditable') === 'true' ||
    el.tabIndex >= 0;

  const visible = (el) => {
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    if (style.opacity === '0') return false;
    const box = el.getBoundingClientRect();
    return box.width > 0 || box.height > 0;
  };

  const lines = [];
  const walk = (el, depth) => {
    if (nodes >= MAX_NODES) {
      truncated = true;
      return;
    }
    const tag = el.tagName;
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return;
    if (el.getAttribute('aria-hidden') === 'true') return;
    if (!visible(el)) return;

    const role = roleOf(el);
    let childDepth = depth;
    if (role) {
      const name = nameOf(el, role);
      const act = actionable(el, role);
      // A ref only where acting on it means something. Naming every heading
      // and paragraph would double the snapshot to describe things the agent
      // can only read — and reading is what browser_read is for.
      let line = '  '.repeat(depth) + '- ' + role;
      if (name) line += ' "' + name + '"';
      if (act) {
        seq += 1;
        const ref = 'e' + seq;
        refs.set(ref, el);
        line += ' [ref=' + ref + ']';
        if (el.disabled) line += ' [disabled]';
        if (el.checked) line += ' [checked]';
        const value = el.value;
        if (value && role === 'textbox') {
          line += ' [value="' + clean(value) + '"]';
        }
      }
      lines.push(line);
      nodes += 1;
      childDepth = depth + 1;
    }
    for (const child of el.children) walk(child, childDepth);
  };

  walk(document.body, 0);
  if (truncated) lines.push('… (snapshot truncated)');

  return JSON.stringify({
    url: location.href,
    title: document.title,
    snapshot: lines.join('\n')
  });
})()
''';

/// Reads the readable text of the page, the way an article is read.
///
/// `innerText` rather than `textContent`: it honours layout, so a nav bar's
/// links arrive as separate lines rather than welded into one word, and hidden
/// elements stay out. `<main>` or `<article>` when the page says which part is
/// the content, since that is the difference between an article and an article
/// wrapped in four hundred words of menu.
const String kBrowserReadScript = r'''
(() => {
  const main =
    document.querySelector('main') ||
    document.querySelector('article') ||
    document.body;
  return JSON.stringify({
    url: location.href,
    title: document.title,
    text: (main.innerText || '').replace(/\n{3,}/g, '\n\n').trim()
  });
})()
''';
