import assert from 'node:assert/strict';
import { computeDiff } from '../engine/diff.js';
import { buildPlan } from '../engine/plan.js';
import { commitSync } from '../engine/commit.js';
import { normalizeChrome, executeChrome } from '../chrome-adapter.js';
import { FakeChrome, FakeSafari } from './fakes.js';

export function env(opts = {}) {
  return { safari: new FakeSafari(), chrome: new FakeChrome(opts), state: { version: 1, mappings: {}, base: { nodes: {}, orders: {} } } };
}

export async function chromeTree(e, store) {
  return normalizeChrome((await e.chrome.getTree())[0], store);
}

export async function diffOnly(e, direction = 'both') {
  const c = await chromeTree(e);
  return computeDiff(e.state, e.safari.tree(), c.tree, { direction });
}

/** One full sync cycle: diff -> plan -> execute both sides -> rescan -> commit -> re-diff. */
export async function cycle(e, { direction = 'both', choose = () => ({}), syncOrder = true, skipCommit = false } = {}) {
  const c = await chromeTree(e);
  const diff = computeDiff(e.state, e.safari.tree(), c.tree, { direction });
  const choices = typeof choose === 'function' ? choose(diff.items) : choose;
  const plan = buildPlan(diff, choices, { syncOrder });
  e.safari.apply(plan.ops.s);
  const cres = await executeChrome(plan.ops.c, e.chrome, c.rootIds);
  assert.equal(cres.error, undefined, `chrome exec error: ${JSON.stringify(cres.error)}`);
  const c2 = await chromeTree(e);
  if (!skipCommit) {
    e.state = commitSync({ state: e.state, diff, plan, results: { s: { applied: true }, c: cres }, sTree: e.safari.tree(), cTree: c2.tree });
  }
  const after = computeDiff(e.state, e.safari.tree(), c2.tree, { direction });
  return { diff, plan, after, cres };
}

/** Flatten a normalized tree into ordered lines "root/folder/title|url" */
export function flat(tree) {
  const out = [];
  const walk = (n, path) => {
    for (const ch of n.children || []) {
      const p = `${path}/${ch.title}`;
      out.push(ch.kind === 'bookmark' ? `${p}|${canon(ch.url)}` : `${p}/`);
      if (ch.kind === 'folder') walk(ch, p);
    }
  };
  for (const [k, r] of Object.entries(tree.roots)) walk(r, k);
  return out;
}

function canon(u) { try { return new URL(u).href; } catch { return u; } }

export async function assertInSync(e) {
  const c = await chromeTree(e);
  assert.deepEqual(flat(c.tree), flat(e.safari.tree()));
}

export const pick = (items, pred) => items.filter(pred);
export const choose = (map) => (items) => {
  const out = {};
  for (const it of items) {
    for (const [prefix, choice] of Object.entries(map)) if (it.id.startsWith(prefix) || it.type === prefix) out[it.id] = choice;
  }
  return out;
};
