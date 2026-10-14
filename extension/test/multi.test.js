import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Coordinator } from '../engine/coordinator.js';
import { migrateState } from '../engine/multi.js';
import { normalizeChrome, executeChrome } from '../chrome-adapter.js';
import { FakeChrome, FakeSafari } from './fakes.js';
import { env, cycle, flat } from './helpers.js';

function rng(seed) { return () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648); }

function makeWorld({ edge = true } = {}) {
  const safari = new FakeSafari();
  let n = 0;
  safari.uuid = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;
  const browsers = { chrome: new FakeChrome() };
  if (edge) browsers.edge = new FakeChrome();
  const online = { safari: true, chrome: true, edge: true };
  const store = { state: null, rev: 0 };
  const mem = new Map();
  const eps = {
    safari: {
      id: 'safari', kind: 'safari', browser: 'safari', name: 'Safari',
      get online() { return online.safari; },
      async read() { return { tree: safari.tree(), fingerprint: JSON.stringify(safari.tree()) }; },
      async apply(ops) { safari.apply(ops); return { applied: ops.length }; },
    },
  };
  for (const [id, fake] of Object.entries(browsers)) {
    eps[id] = {
      id, kind: 'chromium', browser: id, name: id === 'chrome' ? 'Chrome' : 'Edge',
      get online() { return online[id]; },
      async read() { const c = normalizeChrome((await fake.getTree())[0]); return { tree: c.tree, fingerprint: JSON.stringify(c.tree) }; },
      async apply(ops) {
        const { rootIds } = normalizeChrome((await fake.getTree())[0]);
        const r = await executeChrome(ops, fake, rootIds);
        return { applied: r.done, created: r.created, error: r.error, done: r.done };
      },
    };
  }
  const coord = new Coordinator({
    store: { load: async () => ({ state: structuredClone(store.state), revision: store.rev }), save: async (s, rev) => { assert.equal(rev, store.rev, 'stale revision'); store.state = structuredClone(s); return ++store.rev; } },
    settings: { load: async () => mem.get('settings') || null, save: async (s) => mem.set('settings', structuredClone(s)) },
    endpoints: { list: async () => Object.values(eps) },
    kv: { get: async (k) => mem.get(k), set: async (k, v) => mem.set(k, v) },
  });
  return { safari, browsers, online, coord, store, eps };
}

async function sync(w, choose = () => ({})) {
  const s = await w.coord.scan();
  const choices = typeof choose === 'function' ? choose(s.items) : choose;
  const r = await w.coord.run(s.scanId, choices);
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  return { scan: s, run: r };
}

const all = (choice) => (items) => Object.fromEntries(items.map((i) => [i.id, choice(i)]));
const resolveAll = all((i) => (i.choices.includes('apply') ? 'apply' : i.choices.includes('useS') ? 'useS' : i.type === 'multiConflict' ? i.choices[0] : i.default));

async function flats(w) {
  const out = { safari: flat(w.safari.tree()) };
  for (const [id, f] of Object.entries(w.browsers)) out[id] = flat(normalizeChrome((await f.getTree())[0]).tree);
  return out;
}

async function assertConverged(w, ids = Object.keys(w.eps).filter((k) => w.online[k])) {
  const f = await flats(w);
  for (const id of ids.slice(1)) assert.deepEqual(f[id], f[ids[0]], `${id} vs ${ids[0]}`);
}

test('multi: three endpoints first sync merges everything, no duplicates of identical items', async () => {
  const w = makeWorld();
  w.safari.add('root:bar', 'Common', 'https://common.test/');
  w.safari.add('root:bar', 'S only', 'https://s.test/');
  w.browsers.chrome.add('1', 'Common', 'https://common.test/');
  w.browsers.chrome.add('1', 'C only', 'https://c.test/');
  w.browsers.edge.add('1', 'Common', 'https://common.test/');
  const f = w.browsers.edge.add('2', 'E folder');
  w.browsers.edge.add(f, 'E child', 'https://e.test/');
  await sync(w);
  await assertConverged(w);
  const fl = (await flats(w)).safari;
  assert.equal(fl.filter((l) => l.includes('common.test')).length, 1);
  assert.ok(fl.some((l) => l.includes('e.test')));
  const again = await w.coord.scan();
  assert.equal(again.items.length, 0);
  assert.equal(Object.values(again.preview).reduce((a, v) => a + (v.total || 0), 0), 0);
});

test('multi: an offline endpoint catches up without mistaking missed changes for its own deletions', async () => {
  const w = makeWorld();
  const keep = w.safari.add('root:bar', 'Keep', 'https://keep.test/');
  w.safari.add('root:bar', 'Rename me', 'https://rename.test/');
  w.safari.add('root:bar', 'Delete me', 'https://delete.test/');
  await sync(w);
  w.online.edge = false;
  // while Edge is offline
  w.browsers.chrome.add('1', 'Added in Chrome', 'https://added.test/');
  const t = w.safari.tree().roots['root:bar'].children;
  w.safari.find(t[1].id).title = 'Renamed in Safari';
  await sync(w, all((i) => (i.type === 'delete' ? 'apply' : i.default)));
  const del = w.safari.tree().roots['root:bar'].children.find((c) => c.title === 'Delete me');
  w.safari.apply([{ op: 'remove', id: del.id }]);
  await sync(w, all((i) => (i.type === 'delete' ? 'apply' : i.default)));
  // Edge did its own edit offline
  const edgeKeep = w.browsers.edge.nodes.get('1').children.map((id) => w.browsers.edge.nodes.get(id)).find((n) => n.title === 'Keep');
  await w.browsers.edge.update(edgeKeep.id, { title: 'Keep (edited in Edge)' });
  // Edge comes back
  w.online.edge = true;
  const s = await w.coord.scan();
  assert.deepEqual(s.items.map((i) => `${i.ep}:${i.type}`), ['edge:modify'], 'only Edge\'s own edit is a decision');
  assert.ok(s.preview.edge.create >= 1 && s.preview.edge.update >= 1 && s.preview.edge.remove === 1, JSON.stringify(s.preview.edge));
  const r = await w.coord.run(s.scanId, {});
  assert.equal(r.ok, true);
  await assertConverged(w);
  assert.equal(w.safari.find(keep).title, 'Keep (edited in Edge)');
});

test('multi: conflicting edits on two endpoints become one linked item; ignore holds both', async () => {
  const w = makeWorld();
  w.safari.add('root:bar', 'Doc', 'https://doc.test/');
  await sync(w);
  const nodeIn = (f) => w.browsers[f].nodes.get(w.browsers[f].nodes.get('1').children[0]);
  await w.browsers.chrome.update(nodeIn('chrome').id, { title: 'Chrome title' });
  await w.browsers.edge.update(nodeIn('edge').id, { title: 'Edge title' });
  const s = await w.coord.scan();
  assert.equal(s.items.length, 1, JSON.stringify(s.items.map((i) => i.id)));
  const it = s.items[0];
  assert.equal(it.type, 'multiConflict');
  assert.deepEqual(it.endpoints.map((e) => e.name).sort(), ['Chrome', 'Edge']);
  assert.deepEqual(it.endpoints.map((e) => e.title).sort(), ['Chrome title', 'Edge title']);
  // ignore: nothing changes anywhere
  const r0 = await w.coord.run(s.scanId, {});
  assert.equal(r0.ok, true);
  assert.equal(nodeIn('chrome').title, 'Chrome title');
  assert.equal(nodeIn('edge').title, 'Edge title');
  assert.equal(w.safari.tree().roots['root:bar'].children[0].title, 'Doc');
  // resolve with Edge's version
  const s2 = await w.coord.scan();
  assert.equal(s2.items.length, 1);
  await w.coord.run(s2.scanId, { [s2.items[0].id]: 'use:edge' });
  await assertConverged(w);
  assert.equal(w.safari.tree().roots['root:bar'].children[0].title, 'Edge title');
  assert.equal((await w.coord.scan()).items.length, 0);
});

test('multi: delete on one endpoint vs edit on another is one decision', async () => {
  const w = makeWorld();
  w.safari.add('root:bar', 'Doc', 'https://doc.test/');
  await sync(w);
  const cid = w.browsers.chrome.nodes.get('1').children[0];
  await w.browsers.chrome.removeTree(cid);
  const eid = w.browsers.edge.nodes.get('1').children[0];
  await w.browsers.edge.update(eid, { title: 'Edited in Edge' });
  const s = await w.coord.scan();
  assert.deepEqual(s.items.map((i) => i.type), ['multiConflict']);
  await w.coord.run(s.scanId, { [s.items[0].id]: 'use:edge' });
  await assertConverged(w);
  assert.equal(w.safari.tree().roots['root:bar'].children[0].title, 'Edited in Edge');
  const s3 = await w.coord.scan();
  assert.equal(s3.items.length, 0);
  // and the other way round
  await w.browsers.chrome.removeTree(w.browsers.chrome.nodes.get('1').children[0]);
  await w.browsers.edge.update(w.browsers.edge.nodes.get('1').children[0], { title: 'Again' });
  const s4 = await w.coord.scan();
  await w.coord.run(s4.scanId, { [s4.items[0].id]: 'use:chrome' });
  await assertConverged(w);
  assert.equal(w.safari.tree().roots['root:bar'].children.length, 0);
});

test('multi: receive-only and send-only endpoints', async () => {
  const w = makeWorld();
  w.safari.add('root:bar', 'Base', 'https://base.test/');
  await sync(w);
  await w.coord.saveSettings({ endpoints: { edge: { mode: 'receive' }, chrome: { mode: 'send' } } });
  w.browsers.edge.add('1', 'Edge local', 'https://edge-local.test/');
  w.browsers.chrome.add('1', 'From Chrome', 'https://from-chrome.test/');
  w.safari.add('root:bar', 'From Safari', 'https://from-safari.test/');
  await sync(w);
  const f = await flats(w);
  assert.ok(f.safari.some((l) => l.includes('from-chrome')), 'send-only Chrome sends');
  assert.ok(!f.chrome.some((l) => l.includes('from-safari')), 'send-only Chrome does not receive');
  assert.ok(f.edge.some((l) => l.includes('from-safari')) && f.edge.some((l) => l.includes('from-chrome')), 'receive-only Edge receives');
  assert.ok(!f.safari.some((l) => l.includes('edge-local')), 'receive-only Edge does not send');
  assert.ok(f.edge.some((l) => l.includes('edge-local')), 'and keeps its local item');
});

test('multi: v1 state migrates with zero changes', async () => {
  // produce a real v1 state with the two-sided engine
  const e = env();
  const f = e.safari.add('root:bar', '工作');
  e.safari.add(f, 'A', 'https://a.test/');
  e.safari.add('root:bar', 'B', 'https://b.test/');
  e.chrome.add('1', 'C', 'https://c.test/');
  await cycle(e);
  // a pending Safari change must stay a decision after migration
  e.safari.find(e.safari.tree().roots['root:bar'].children[1].id).title = 'B renamed';
  const w = makeWorld({ edge: false });
  w.safari.roots = e.safari.roots;
  w.browsers.chrome = e.chrome;
  w.eps.chrome.read = async () => { const c = normalizeChrome((await e.chrome.getTree())[0]); return { tree: c.tree, fingerprint: JSON.stringify(c.tree) }; };
  w.eps.chrome.apply = async (ops) => { const { rootIds } = normalizeChrome((await e.chrome.getTree())[0]); const r = await executeChrome(ops, e.chrome, rootIds); return { applied: r.done, created: r.created }; };
  w.store.state = e.state; // v1
  const s = await w.coord.scan();
  assert.deepEqual(s.items.map((i) => `${i.ep}:${i.type}`), ['safari:modify']);
  assert.equal(s.preview.chrome.total, 1, 'only the pending rename would be written');
  assert.equal(migrateState(e.state).version, 2);
  await w.coord.run(s.scanId, {});
  const again = await w.coord.scan();
  assert.equal(again.items.length, 0);
  assert.equal(flat(normalizeChrome((await e.chrome.getTree())[0]).tree).filter((l) => l.includes('B renamed')).length, 1);
});

test('multi: randomized edits on three endpoints with endpoints going offline converge', async () => {
  const { randomEdit } = await import('./fuzz-multi-lib.js');
  const seeds = process.env.MULTI_SEEDS ? Array.from({ length: +process.env.MULTI_SEEDS }, (_, i) => i * 7 + 1) : [3, 11, 29, 47];
  const rounds = +(process.env.MULTI_ROUNDS || 30);
  for (const seed of seeds) {
    const rnd = rng(seed);
    const w = makeWorld();
    for (let i = 0; i < 5; i++) w.safari.add('root:bar', `seed${i}`, `https://seed${i}.test/`);
    await sync(w);
    for (let round = 0; round < rounds; round++) {
      // flip availability
      for (const id of ['chrome', 'edge']) if (rnd() < 0.2) w.online[id] = !w.online[id];
      for (let k = 0; k < 2; k++) await randomEdit(w, rnd, `${seed}_${round}_${k}`);
      await sync(w, all((i) => (rnd() < 0.3 ? 'ignore' : i.choices[Math.floor(rnd() * i.choices.length)])));
      for (let pass = 0; pass < 2; pass++) await sync(w, resolveAll);
      const s = await w.coord.scan();
      assert.deepEqual(s.items.map((i) => i.id), [], `seed ${seed} round ${round}: leftovers`);
      await assertConverged(w);
    }
    w.online.chrome = true; w.online.edge = true;
    for (let pass = 0; pass < 3; pass++) await sync(w, resolveAll);
    await assertConverged(w);
  }
});

test('multi/auto: small deletions propagate only with autoDelete, within the cap', async () => {
  const w = makeWorld({ edge: false });
  for (let i = 0; i < 8; i++) w.safari.add('root:bar', `b${i}`, `https://b${i}.test/`);
  await sync(w);
  await w.browsers.chrome.removeTree(w.browsers.chrome.nodes.get('1').children[0]);
  let r = await w.coord.autoRun();
  assert.equal(r.heldDeletes, 1);
  assert.equal(w.safari.tree().roots['root:bar'].children.length, 8);
  await w.coord.saveSettings({ autoDelete: true });
  r = await w.coord.autoRun();
  assert.equal(r.ok, true);
  assert.equal(w.safari.tree().roots['root:bar'].children.length, 7);
  for (let i = 0; i < 6; i++) await w.browsers.chrome.removeTree(w.browsers.chrome.nodes.get('1').children[0]);
  r = await w.coord.autoRun();
  assert.equal(r.skipped, 'nothing');
  assert.equal(r.heldDeletes, 6);
});

test('multi/auto: small reorder syncs automatically, a mass re-sort waits', async () => {
  const w = makeWorld({ edge: false });
  for (let i = 0; i < 8; i++) w.safari.add('root:bar', `f${i}`, `https://f${i}.test/`);
  await sync(w);
  const kids = w.safari.roots['root:bar'].children;
  kids.unshift(kids.pop());
  let r = await w.coord.autoRun();
  assert.equal(r.ok, true);
  await assertConverged(w);
  w.safari.roots['root:bar'].children.reverse();
  r = await w.coord.autoRun();
  assert.equal(r.skipped, 'nothing');
  const s = await w.coord.scan();
  assert.equal(s.items.filter((i) => i.type === 'order' && i.suspicious).length, 1);
});

test('multi/auto: Safari write deferred when the endpoint defers; Chrome side still applied', async () => {
  const w = makeWorld({ edge: false });
  w.safari.add('root:bar', 'S1', 'https://s1.test/');
  await sync(w);
  const realApply = w.eps.safari.apply;
  w.eps.safari.apply = async () => ({ deferred: true, reason: 'Safari 正在运行' });
  w.browsers.chrome.add('1', 'from chrome', 'https://fc.test/');
  w.safari.add('root:bar', 'from safari', 'https://fs.test/');
  const s = await w.coord.scan();
  const r = await w.coord.run(s.scanId, {});
  assert.ok(r.endpoints.safari.deferred >= 1);
  assert.ok(r.endpoints.chrome.applied >= 1);
  w.eps.safari.apply = realApply;
  const r2 = await sync(w);
  assert.equal(r2.run.ok, true);
  await assertConverged(w);
});

test('multi: a default decision that writes back to the endpoint is executed (not only explicit choices)', async () => {
  const w = makeWorld();
  for (let i = 0; i < 8; i++) w.safari.add('root:bar', `f${i}`, `https://f${i}.test/`);
  await sync(w);
  w.browsers.edge.nodes.get('1').children.reverse(); // suspicious re-sort on Edge; default = others' order
  const s = await w.coord.scan();
  const it = s.items.find((i) => i.type === 'order');
  assert.equal(it.default, 'useS');
  await w.coord.run(s.scanId, {});
  await assertConverged(w);
  assert.equal((await w.coord.scan()).items.length, 0);
  assert.equal(w.safari.tree().roots['root:bar'].children[0].title, 'f0');
});
