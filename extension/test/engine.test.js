import { test } from 'node:test';
import assert from 'node:assert/strict';
import { env, cycle, diffOnly, assertInSync, flat, chromeTree, choose } from './helpers.js';
import { mergeOrder } from '../engine/plan.js';
import { lcsSet } from '../engine/util.js';

const BAR_S = 'root:bar';
const BAR_C = '1';
const OTHER_C = '2';

async function seeded() {
  const e = env();
  const f = e.safari.add(BAR_S, '工作');
  e.safari.add(f, 'Example', 'https://example.com');
  e.safari.add(f, 'Docs', 'https://docs.example.com/a');
  e.safari.add(BAR_S, 'News', 'https://news.example.com/');
  e.safari.add('root:other', 'Menu item', 'https://menu.example.com/');
  const r = await cycle(e);
  assert.equal(r.after.items.length, 0, 'seed sync leaves nothing behind');
  await assertInSync(e);
  return e;
}

test('first sync merges both sides and keeps duplicates', async () => {
  const e = env();
  e.safari.add(BAR_S, 'A', 'https://a.test/');
  e.safari.add(BAR_S, 'Dup', 'https://dup.test/');
  e.safari.add(BAR_S, 'Dup', 'https://dup.test/');
  e.chrome.add(BAR_C, 'A', 'https://a.test/');
  e.chrome.add(BAR_C, 'B', 'https://b.test/');
  const { diff, after } = await cycle(e);
  assert.equal(diff.stats.pairs, 1, 'A paired, not duplicated');
  assert.equal(after.items.length, 0);
  await assertInSync(e);
  const c = await chromeTree(e);
  assert.equal(flat(c.tree).filter((l) => l.includes('dup.test')).length, 2);
});

test('no changes -> no ops (idempotent)', async () => {
  const e = await seeded();
  const r = await cycle(e);
  assert.equal(r.diff.items.length, 0);
  assert.equal(r.plan.ops.s.length + r.plan.ops.c.length, 0);
});

test('URL canonicalization does not create spurious diffs', async () => {
  const e = env();
  e.safari.add(BAR_S, 'Host only', 'https://Example.COM');
  await cycle(e);
  const c = await chromeTree(e);
  assert.equal(c.tree.roots['root:bar'].children[0].url, 'https://example.com/');
  const d = await diffOnly(e);
  assert.equal(d.items.length, 0);
});

test('title edit in Safari propagates to Chrome', async () => {
  const e = await seeded();
  e.safari.find(e.safari.tree().roots[BAR_S].children[1].id).title = 'News (renamed)';
  const r = await cycle(e);
  assert.deepEqual(r.diff.items.map((i) => i.type), ['modify']);
  assert.equal(r.plan.ops.s.length, 0);
  await assertInSync(e);
});

test('url edit in Chrome propagates to Safari', async () => {
  const e = await seeded();
  const bar = e.chrome.nodes.get(BAR_C);
  const newsId = bar.children[1];
  await e.chrome.update(newsId, { url: 'https://news2.example.com/' });
  const r = await cycle(e);
  assert.equal(r.diff.items[0].from, 'c');
  assert.deepEqual(r.diff.items[0].fields, ['url']);
  await assertInSync(e);
});

test('move into another folder propagates', async () => {
  const e = await seeded();
  const t = e.safari.tree();
  const news = t.roots[BAR_S].children[1];
  const folder = t.roots[BAR_S].children[0];
  e.safari.apply([{ op: 'move', id: news.id, parent: folder.id, after: null }]);
  const r = await cycle(e);
  assert.equal(r.after.items.length, 0);
  await assertInSync(e);
});

test('deletion is shown but not applied by default; applies when chosen', async () => {
  const e = await seeded();
  const news = e.safari.tree().roots[BAR_S].children[1];
  e.safari.apply([{ op: 'remove', id: news.id }]);
  const r1 = await cycle(e);
  assert.equal(r1.diff.items.length, 1);
  assert.equal(r1.diff.items[0].type, 'delete');
  assert.equal(r1.diff.items[0].default, 'ignore');
  assert.equal(r1.plan.ops.c.length, 0);
  assert.equal(r1.after.items.length, 1, 'ignored delete keeps showing up');
  const r2 = await cycle(e, { choose: choose({ 'del:': 'apply' }) });
  assert.equal(r2.after.items.length, 0);
  await assertInSync(e);
});

test('restore brings a deleted folder subtree back with new UUIDs', async () => {
  const e = await seeded();
  const folder = e.safari.tree().roots[BAR_S].children[0];
  e.safari.apply([{ op: 'remove', id: folder.id }]);
  const r = await cycle(e, { choose: choose({ 'del:': 'restore' }) });
  assert.equal(r.diff.items.length, 1, 'one item covers the whole folder');
  assert.equal(r.diff.items[0].count, 3);
  assert.equal(r.after.items.length, 0);
  await assertInSync(e);
});

test('conflicting title edits become a conflict; useC resolves', async () => {
  const e = await seeded();
  const sNews = e.safari.tree().roots[BAR_S].children[1];
  e.safari.find(sNews.id).title = 'S title';
  await e.chrome.update(e.chrome.nodes.get(BAR_C).children[1], { title: 'C title' });
  const d = await diffOnly(e);
  assert.equal(d.items.length, 1);
  assert.equal(d.items[0].type, 'conflict');
  assert.equal(d.items[0].default, 'ignore');
  const r = await cycle(e, { choose: choose({ conflict: 'useC' }) });
  assert.equal(r.after.items.length, 0);
  assert.equal(e.safari.find(sNews.id).title, 'C title');
});

test('non-overlapping edits on both sides merge automatically', async () => {
  const e = await seeded();
  const sNews = e.safari.tree().roots[BAR_S].children[1];
  e.safari.find(sNews.id).title = 'S title';
  await e.chrome.update(e.chrome.nodes.get(BAR_C).children[1], { url: 'https://c.example/' });
  const r = await cycle(e);
  assert.deepEqual(r.diff.items.map((i) => i.type).sort(), ['modify', 'modify']);
  assert.equal(r.after.items.length, 0);
  await assertInSync(e);
});

test('delete on one side vs modification on the other is a conflict', async () => {
  const e = await seeded();
  const folder = e.safari.tree().roots[BAR_S].children[0];
  e.safari.apply([{ op: 'remove', id: folder.id }]);
  const cFolder = e.chrome.nodes.get(BAR_C).children[0];
  e.chrome.add(cFolder, 'Added in Chrome', 'https://new.test/');
  const d = await diffOnly(e);
  assert.equal(d.items.length, 1);
  assert.equal(d.items[0].type, 'deleteConflict');
  const r = await cycle(e, { choose: choose({ 'del:': 'restore' }) });
  assert.equal(r.after.items.length, 0);
  await assertInSync(e);
});

test('new folder with children in Chrome is created in Safari in order', async () => {
  const e = await seeded();
  const f = e.chrome.add(OTHER_C, '新文件夹');
  e.chrome.add(f, 'one', 'https://1.test/');
  e.chrome.add(f, 'two', 'https://2.test/');
  const sub = e.chrome.add(f, 'sub');
  e.chrome.add(sub, 'three', 'https://3.test/');
  const r = await cycle(e);
  assert.equal(r.diff.items.length, 1);
  assert.equal(r.diff.items[0].count, 5);
  assert.equal(r.plan.ops.s.filter((o) => o.op === 'create').length, 5);
  await assertInSync(e);
});

test('reorder in Chrome propagates to Safari', async () => {
  const e = await seeded();
  const bar = e.chrome.nodes.get(BAR_C);
  await e.chrome.move(bar.children[1], { parentId: BAR_C, index: 0 });
  const r = await cycle(e);
  assert.ok(r.plan.ops.s.some((o) => o.reorder));
  await assertInSync(e);
  assert.equal(r.after.items.length, 0);
});

test('new items land next to their source predecessor', async () => {
  const e = await seeded();
  const t = e.safari.tree();
  const folder = t.roots[BAR_S].children[0];
  const first = folder.children[0];
  const id = e.safari.uuid();
  e.safari.apply([{ op: 'create', id, kind: 'bookmark', title: 'Middle', url: 'https://mid.test/', parent: folder.id, after: first.id }]);
  await cycle(e);
  await assertInSync(e);
  const c = await chromeTree(e);
  assert.equal(c.tree.roots['root:bar'].children[0].children[1].title, 'Middle');
});

test('Safari UUID rebuild of a folder is re-identified, no spurious changes', async () => {
  const e = await seeded();
  const folder = e.safari.find(e.safari.tree().roots[BAR_S].children[0].id);
  folder.id = 'REBUILT-UUID'; // iCloud / Safari rewrote the List UUID, children kept theirs
  const r = await cycle(e);
  assert.equal(r.diff.stats.rebinds, 1);
  assert.equal(r.diff.items.length, 0);
  const again = await diffOnly(e);
  assert.equal(again.items.length, 0);
});

test('one-way s2c never writes Safari and defaults Chrome-side edits to ignore', async () => {
  const e = await seeded();
  await e.chrome.update(e.chrome.nodes.get(BAR_C).children[1], { title: 'changed in chrome' });
  e.chrome.add(BAR_C, 'chrome only', 'https://co.test/');
  const r = await cycle(e, { direction: 's2c' });
  assert.equal(r.plan.ops.s.length, 0);
  assert.equal(r.plan.ops.c.length, 0);
  for (const it of r.diff.items) {
    assert.equal(it.default, 'ignore');
    assert.ok(it.choices.every((c) => c.id === 'ignore' || c.writes === 'c'));
  }
  // user can revert target to source state
  const r2 = await cycle(e, { direction: 's2c', choose: choose({ 'mod:': 'revert', 'new:': 'remove' }) });
  assert.equal(r2.after.items.length, 0);
  await assertInSync(e);
});

test('moving an existing bookmark into a brand-new folder', async () => {
  const e = await seeded();
  const t = e.safari.tree();
  const news = t.roots[BAR_S].children[1];
  const nid = e.safari.uuid();
  e.safari.apply([
    { op: 'create', id: nid, kind: 'folder', title: 'Fresh', parent: 'root:other', after: 'END' },
    { op: 'move', id: news.id, parent: nid, after: 'END' },
  ]);
  const r = await cycle(e);
  assert.equal(r.after.items.length, 0, JSON.stringify(r.after.items.map((i) => i.id)));
  await assertInSync(e);
});

test('folder delete after moving a child out keeps the child', async () => {
  const e = await seeded();
  const t = e.safari.tree();
  const folder = t.roots[BAR_S].children[0];
  const child = folder.children[0];
  e.safari.apply([
    { op: 'move', id: child.id, parent: 'root:other', after: 'END' },
    { op: 'remove', id: folder.id },
  ]);
  // only the delete, without the move -> the survivor is relocated first, never destroyed
  const d0 = await diffOnly(e);
  const onlyDelete = {};
  for (const it of d0.items) onlyDelete[it.id] = it.type === 'delete' ? 'apply' : 'ignore';
  const { buildPlan } = await import('../engine/plan.js');
  const p0 = buildPlan(d0, onlyDelete);
  assert.deepEqual(p0.warnings, []);
  const kinds = p0.ops.c.filter((o) => !o.reorder).map((o) => o.op);
  assert.deepEqual(kinds, ['move', 'remove']);
  // with both
  const r = await cycle(e, { choose: choose({ 'del:': 'apply' }) });
  assert.equal(r.after.items.length, 0);
  await assertInSync(e);
});

test('interrupted Chrome execution does not duplicate on retry', async () => {
  const e = await seeded();
  e.safari.add('root:other', 'X1', 'https://x1.test/');
  e.safari.add('root:other', 'X2', 'https://x2.test/');
  // run but "crash" before commit
  await cycle(e, { skipCommit: true });
  const r = await cycle(e);
  assert.equal(r.plan.ops.c.filter((o) => o.op === 'create').length, 0, 'paired instead of recreated');
  await assertInSync(e);
  const c = await chromeTree(e);
  assert.equal(flat(c.tree).filter((l) => l.includes('x1.test')).length, 1);
});

test('mass disappearance raises a warning', async () => {
  const e = env();
  for (let i = 0; i < 20; i++) e.safari.add(BAR_S, `b${i}`, `https://b${i}.test/`);
  await cycle(e);
  e.safari.roots[BAR_S].children = e.safari.roots[BAR_S].children.slice(0, 5);
  const d = await diffOnly(e);
  assert.ok(d.warnings.some((w) => w.code === 'massMissing' && w.side === 's'));
  assert.ok(d.items.every((i) => i.default === 'ignore'));
});

test('Chrome account storage is preferred in auto mode', async () => {
  const e = env({ account: true });
  e.chrome.add('4', 'acct', 'https://acct.test/');
  e.chrome.add('1', 'local', 'https://local.test/');
  const auto = await chromeTree(e, 'auto');
  assert.equal(auto.rootIds['root:bar'], '4');
  const local = await chromeTree(e, 'local');
  assert.equal(local.rootIds['root:bar'], '1');
});

test('special / readonly nodes are ignored and untouched', async () => {
  const e = env();
  e.safari.add(BAR_S, 'A', 'https://a.test/');
  e.safari.roots[BAR_S].children.push({ id: 'PROXY', kind: 'special', title: 'History' });
  const r = await cycle(e);
  assert.equal(r.diff.stats.s.ignored, 1);
  assert.ok(e.safari.find('PROXY'));
});

test('mergeOrder / lcs helpers', () => {
  assert.deepEqual(mergeOrder(['a', 'b', 'c'], ['a', 'x', 'c', 'y']), ['a', 'x', 'b', 'c', 'y']);
  assert.deepEqual(mergeOrder(['a'], ['z', 'a']), ['z', 'a']);
  assert.deepEqual([...lcsSet(['a', 'b', 'c', 'd'], ['b', 'a', 'd', 'c'])].length, 2);
});

test('randomized edits converge (fuzz)', async () => {
  let seed = 42;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  const e = await seeded();
  for (let round = 0; round < 40; round++) {
    // random edit on a random side
    const side = rnd() < 0.5 ? 's' : 'c';
    const act = Math.floor(rnd() * 4);
    if (side === 's') {
      const all = [];
      const walk = (n) => { for (const c of n.children || []) { all.push(c); walk(c); } };
      for (const r of Object.values(e.safari.roots)) walk(r);
      const folders = [...Object.values(e.safari.roots), ...all.filter((n) => n.kind === 'folder')];
      const target = all[Math.floor(rnd() * all.length)];
      const folder = folders[Math.floor(rnd() * folders.length)];
      if (act === 0 || !target) e.safari.add(folder, `s${round}`, rnd() < 0.3 ? undefined : `https://s${round}.test/`);
      else if (act === 1) target.title += '*';
      else if (act === 2) { try { e.safari.apply([{ op: 'move', id: target.id, parent: folder.id, after: null }]); } catch { /* cycle */ } }
      else e.safari.apply([{ op: 'remove', id: target.id }]);
    } else {
      const ids = [...e.chrome.nodes.keys()].filter((id) => !['0', '1', '2', '3'].includes(id));
      const folders = ['1', '2', ...ids.filter((id) => e.chrome.nodes.get(id).url === undefined)];
      const target = ids[Math.floor(rnd() * ids.length)];
      const folder = folders[Math.floor(rnd() * folders.length)];
      if (act === 0 || !target) e.chrome.add(folder, `c${round}`, rnd() < 0.3 ? undefined : `https://c${round}.test/`);
      else if (act === 1) await e.chrome.update(target, { title: e.chrome.nodes.get(target).title + '+' });
      else if (act === 2) { try { await e.chrome.move(target, { parentId: folder, index: 0 }); } catch { /* ignore */ } }
      else await e.chrome.removeTree(target);
    }
    // wrap moves that created cycles in the fake chrome are not possible (fake has no check) -> guard
    const r = await cycle(e, { choose: choose({ 'del:': 'apply', conflict: 'useS' }) });
    assert.equal(r.plan.warnings.filter((w) => w.code !== 'unsafeRemove').length, 0, JSON.stringify(r.plan.warnings));
    const leftover = r.after.items.filter((i) => !(i.type === 'delete' && r.plan.warnings.length));
    assert.equal(leftover.length, 0, `round ${round}: ${JSON.stringify(leftover.map((i) => i.id))}`);
    await assertInSync(e);
  }
});


// ---- sibling order (regression: first sync re-sorted folders by pinyin) -------------

test('first sync keeps Chrome folder order (not the diff list order)', async () => {
  const e = env();
  e.safari.add(BAR_S, '如何从 0 开始配置 MacBook Pro', 'https://how.test/');
  const names = ['学习考试相关', '国家企业信用信息公示系统', '公司常用地址', '项目相关', 'AI工具箱', '团队项目', '娱乐小说', 'kindel相关', '工作学习', 'MACOS', '网站搭建', '其它书签'];
  for (const n of names) { const f = e.chrome.add(BAR_C, n); e.chrome.add(f, `${n}-1`, `https://${encodeURIComponent(n)}.test/`); }
  const r = await cycle(e);
  assert.equal(r.after.items.length, 0, JSON.stringify(r.after.items.map((i) => i.id)));
  const c = await chromeTree(e);
  const cOrder = c.tree.roots['root:bar'].children.map((x) => x.title);
  assert.deepEqual(cOrder.filter((t) => names.includes(t)), names, 'Chrome order untouched');
  const sOrder = e.safari.tree().roots['root:bar'].children.map((x) => x.title);
  assert.deepEqual(sOrder, cOrder, 'Safari follows Chrome');
});

async function orderSeed(n = 8) {
  const e = env();
  for (let i = 0; i < n; i++) e.safari.add(BAR_S, `f${i}`, `https://f${i}.test/`);
  await cycle(e);
  return e;
}

test('small user reorder on Safari is an order item defaulting to Safari, applied', async () => {
  const e = await orderSeed();
  const kids = e.safari.roots[BAR_S].children;
  kids.unshift(kids.pop()); // move last to first: 1 moved
  const d = await diffOnly(e);
  const it = d.items.find((i) => i.type === 'order');
  assert.ok(it);
  assert.equal(it.changedBy, 's');
  assert.equal(it.suspicious, false);
  assert.equal(it.default, 'useS');
  await cycle(e);
  const c = await chromeTree(e);
  assert.equal(c.tree.roots['root:bar'].children[0].title, 'f7');
});

test('mass re-sort on Safari is suspicious; default keeps Chrome order', async () => {
  const e = await orderSeed();
  e.safari.roots[BAR_S].children.reverse();
  const d = await diffOnly(e);
  const it = d.items.find((i) => i.type === 'order');
  assert.equal(it.suspicious, true);
  assert.equal(it.default, 'useC');
  await cycle(e);
  assert.deepEqual(e.safari.tree().roots[BAR_S].children.map((x) => x.title), ['f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7']);
});

test('order item ignored keeps both orders and keeps showing up', async () => {
  const e = await orderSeed();
  e.safari.roots[BAR_S].children.reverse();
  const r = await cycle(e, { choose: choose({ 'order:': 'ignore' }) });
  assert.equal(r.plan.ops.c.length + r.plan.ops.s.length, 0);
  assert.equal(r.after.items.filter((i) => i.type === 'order').length, 1);
});

test('orderMaster s makes Safari win when unclear', async () => {
  const e = await orderSeed();
  e.safari.roots[BAR_S].children.reverse();
  const c = await chromeTree(e);
  const { computeDiff } = await import('../engine/diff.js');
  const d = computeDiff(e.state, e.safari.tree(), c.tree, { orderMaster: 's' });
  assert.equal(d.items.find((i) => i.type === 'order').default, 'useS');
});
