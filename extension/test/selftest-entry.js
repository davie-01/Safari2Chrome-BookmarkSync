// Bundled for the Swift test suite: runs a multi-endpoint scenario inside JavaScriptCore
// (no URL, no structuredClone, no Node) and reports the result as JSON.
import '../engine/host.js';
import { Coordinator } from '../engine/coordinator.js';
import { normalizeChrome, executeChrome } from '../chrome-adapter.js';
import { FakeChrome, FakeSafari } from './fakes.js';
import { canonicalize } from '../engine/url.js';

function flat(tree) {
  const out = [];
  const walk = (n, p) => { for (const c of n.children || []) { const q = `${p}/${c.title}`; out.push(c.kind === 'bookmark' ? `${q}|${canonicalize(c.url) ?? c.url}` : `${q}/`); if (c.kind === 'folder') walk(c, q); } };
  for (const [k, r] of Object.entries(tree.roots)) walk(r, k);
  return out.join('\n');
}

async function scenario() {
  const log = [];
  const check = (cond, msg) => { if (!cond) throw new Error(msg); log.push(`ok: ${msg}`); };
  const safari = new FakeSafari();
  let n = 0;
  safari.uuid = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;
  const browsers = { chrome: new FakeChrome(), edge: new FakeChrome() };
  const online = { safari: true, chrome: true, edge: true };
  const store = { state: null, rev: 0 };
  const mem = new Map();
  const eps = [{
    id: 'safari', kind: 'safari', browser: 'safari', name: 'Safari', get online() { return online.safari; },
    read: async () => ({ tree: safari.tree(), fingerprint: JSON.stringify(safari.tree()) }),
    apply: async (ops) => { safari.apply(ops); return { applied: ops.length }; },
  }];
  for (const [id, f] of Object.entries(browsers)) eps.push({
    id, kind: 'chromium', browser: id, name: id, get online() { return online[id]; },
    read: async () => { const c = normalizeChrome((await f.getTree())[0]); return { tree: c.tree, fingerprint: JSON.stringify(c.tree) }; },
    apply: async (ops) => { const { rootIds } = normalizeChrome((await f.getTree())[0]); const r = await executeChrome(ops, f, rootIds); return { applied: r.done, created: r.created, error: r.error }; },
  });
  const coord = new Coordinator({
    store: { load: async () => ({ state: structuredClone(store.state), revision: store.rev }), save: async (s) => { store.state = structuredClone(s); return ++store.rev; } },
    settings: { load: async () => null, save: async () => {} },
    endpoints: { list: async () => eps },
    kv: { get: async (k) => mem.get(k), set: async (k, v) => { mem.set(k, v); } },
  });
  const sync = async (choose = () => ({})) => { const s = await coord.scan(); const r = await coord.run(s.scanId, choose(s.items)); if (!r.ok) throw new Error(JSON.stringify(r.errors)); return s; };
  const trees = async () => ({ s: flat(safari.tree()), c: flat(normalizeChrome((await browsers.chrome.getTree())[0]).tree), e: flat(normalizeChrome((await browsers.edge.getTree())[0]).tree) });

  safari.add('root:bar', 'Common', 'https://common.test/');
  safari.add('root:bar', '中文 书签', 'https://例子.测试/路径 a?q=中#x');
  browsers.chrome.add('1', 'Common', 'https://Common.TEST');
  browsers.edge.add('2', 'Edge only', 'https://edge.test/');
  await sync();
  let t = await trees();
  check(t.s === t.c && t.c === t.e, 'three endpoints converge');
  check(t.s.split('\n').filter((l) => l.includes('common.test')).length === 1, 'identical bookmark paired, not duplicated');
  check((await coord.scan()).items.length === 0, 'second scan is empty');

  online.edge = false;
  safari.add('root:other', 'While Edge was away', 'https://away.test/');
  await sync();
  online.edge = true;
  const s = await coord.scan();
  check(s.items.length === 0 && s.preview.edge.create === 1, 'offline endpoint receives missed change, no false deletion');
  await coord.run(s.scanId, {});
  t = await trees();
  check(t.s === t.e, 'edge caught up');
  check(canonicalize('HTTP://例子.测试:80/a/../b c') === 'http://xn--fsqu00a.xn--0zwm56d/b%20c', 'url polyfill');
  return log;
}

globalThis.BMS_SELFTEST = {
  run() {
    return scenario().then((log) => JSON.stringify({ ok: true, log }), (e) => JSON.stringify({ ok: false, error: String(e && e.stack || e) }));
  },
};
