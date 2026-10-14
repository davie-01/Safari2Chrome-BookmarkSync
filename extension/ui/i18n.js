// Chinese is the source language; en.json maps each Chinese string to English. The macOS app
// ships the same file, so the app and the browser extension say the same thing.
//
//   t('备份保留 {n} 天', { n: 30 })

let lang = 'zh';
let dict = {};

export function currentLang() { return lang; }

export function systemLang() {
  const l = (navigator.language || 'zh').toLowerCase();
  return l.startsWith('zh') ? 'zh' : 'en';
}

/** setting: 'system' | 'zh' | 'en' */
export async function useLang(setting) {
  const want = !setting || setting === 'system' ? systemLang() : setting;
  if (want === 'en' && !Object.keys(dict).length) {
    try { dict = await (await fetch(new URL('en.json', import.meta.url))).json(); } catch { dict = {}; }
  }
  lang = want;
  return lang;
}

export function t(zh, vars) {
  let s = (lang === 'en' && dict[zh]) || zh;
  if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] === undefined ? m : vars[k]));
  return s;
}

/** Translates the markup that ships in index.html: text nodes, placeholders and titles. */
export function translateDom(root = document.body) {
  if (lang !== 'en') return;
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walk.nextNode()) nodes.push(walk.currentNode);
  for (const n of nodes) {
    const raw = n.nodeValue.trim();
    if (raw && dict[raw]) n.nodeValue = n.nodeValue.replace(raw, dict[raw]);
  }
  for (const el of root.querySelectorAll('[placeholder]')) {
    const p = el.getAttribute('placeholder');
    if (dict[p]) el.setAttribute('placeholder', dict[p]);
  }
  for (const el of root.querySelectorAll('[title]')) {
    const v = el.getAttribute('title');
    if (dict[v]) el.setAttribute('title', dict[v]);
  }
  if (dict[document.title]) document.title = dict[document.title];
}

/** Date/number formatting in the interface's language. */
export function locale() { return lang === 'en' ? 'en-US' : 'zh-CN'; }
