// Read-only: migrate the current v1 sync state in memory and scan real Safari + Chrome data.
// Never writes anything. Usage: node scripts/dev/migration-dryrun.mjs <safari-dump.json>
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { Coordinator } from '../../extension/engine/coordinator.js';
import { migrateState } from '../../extension/engine/multi.js';
import { normalizeChrome } from '../../extension/chrome-adapter.js';

const home = homedir();
const saved = JSON.parse(readFileSync(`${home}/Library/Application Support/BookmarkSync/state.json`, 'utf8'));
const settings = existsSync(`${home}/Library/Application Support/BookmarkSync/settings.json`) ? JSON.parse(readFileSync(`${home}/Library/Application Support/BookmarkSync/settings.json`, 'utf8')) : {};
const safari = JSON.parse(readFileSync(process.argv[2], 'utf8'));

function chromeApiTree() {
  const conv = (n) => (n.type === 'url' ? { id: n.id, title: n.name, url: n.url } : { id: n.id, title: n.name, children: (n.children || []).map(conv) });
  const tops = [];
  const add = (file, syncing) => {
    const p = `${home}/Library/Application Support/Google/Chrome/Default/${file}`;
    if (!existsSync(p)) return;
    const j = JSON.parse(readFileSync(p, 'utf8'));
    const ft = { bookmark_bar: 'bookmarks-bar', other: 'other', synced: 'mobile' };
    for (const [k, t] of Object.entries(ft)) if (j.roots[k]) tops.push({ ...conv(j.roots[k]), folderType: t, syncing });
  };
  add('Bookmarks', false);
  add('AccountBookmarks', true);
  return { id: '0', title: '', children: tops };
}
const chromeRoot = chromeApiTree();
const store = settings.chromeStore || 'auto';
const ctree = normalizeChrome(chromeRoot, store);
console.log('state v', saved.state?.version ?? 1, 'revision', saved.revision, 'mappings', Object.keys(saved.state?.mappings || {}).length, 'chrome store', ctree.store);

const v2 = migrateState(saved.state);
const eps = [
  { id: 'safari', kind: 'safari', browser: 'safari', name: 'Safari', online: true, read: async () => ({ tree: safari.tree, fingerprint: 's' }), apply: async () => { throw new Error('read-only'); } },
  { id: 'cr-dryrun', kind: 'chromium', browser: 'chrome', name: 'Chrome', online: true, read: async () => ({ tree: ctree.tree, fingerprint: 'c' }), apply: async () => { throw new Error('read-only'); } },
];
const mem = new Map();
const coord = new Coordinator({
  store: { load: async () => ({ state: structuredClone(v2), revision: 0 }), save: async () => { throw new Error('read-only'); } },
  settings: { load: async () => ({ ...settings, endpoints: {} }), save: async () => {} },
  endpoints: { list: async () => eps },
  kv: { get: async (k) => mem.get(k), set: async (k, v) => mem.set(k, v) },
});
const s = await coord.scan();
const cnt = (t) => { let n = 0; const w = (x) => { for (const c of x.children || []) { n++; w(c); } }; for (const r of Object.values(t.roots)) w(r); return n; };
console.log('hub nodes', cnt(v2.hub.tree), 'safari nodes', cnt(safari.tree), 'chrome nodes', cnt(ctree.tree));
console.log('decisions', s.items.length);
for (const it of s.items) console.log('  -', it.ep, it.type, it.origin, JSON.stringify((it.c || it.s || {}).title || it.key), it.fields ? it.fields.join(',') : '', 'default=' + it.default);
console.log('writes', JSON.stringify(s.preview));
