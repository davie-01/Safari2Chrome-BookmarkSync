// After execution: rescan both sides, then advance mappings and the agreed base.
// Base only moves forward for fields on which both sides *currently* agree, so any change
// that was ignored or failed keeps showing up next time instead of being silently lost.

import { buildIndex } from './tree.js';
import { ROOTS, isRoot } from './util.js';

/**
 * @param {object} args
 * @param {object} args.state        previous persisted state
 * @param {object} args.diff         diff the plan was built from
 * @param {object} args.plan         plan that was executed
 * @param {object} args.results      { s: { applied: bool }, c: { created: {key: chromeId} } }
 * @param {object} args.sTree        Safari tree re-read after execution
 * @param {object} args.cTree        Chrome tree re-read after execution
 */
export function commitSync({ state, diff, plan, results, sTree, cTree, now = Date.now() }) {
  const { idOf, rebinds, pairs } = diff.ctx;
  const mappings = structuredClone(state?.mappings || {});
  const oldBase = state?.base || { nodes: {}, orders: {} };

  const ensure = (key) => (mappings[key] ??= {});
  for (const r of rebinds) ensure(r.key)[r.side] = r.to;
  for (const p of pairs) { const m = ensure(p.key); m.s = p.s; m.c = p.c; }

  // creations: ids either pre-assigned in the plan (applied side) or reported by the executor
  for (const side of ['s', 'c']) {
    const o = side === 's' ? 'c' : 's';
    const created = { ...(results?.[side]?.created || {}) };
    if (results?.[side]?.applied) {
      for (const op of plan.ops[side]) if (op.op === 'create' && op.id) created[op.key] = op.id;
    }
    for (const [key, id] of Object.entries(created)) {
      const m = ensure(key);
      m[side] = id;
      if (m[o] == null && idOf[o].has(key)) m[o] = idOf[o].get(key);
    }
  }

  const S = buildIndex(sTree), C = buildIndex(cTree);
  const keyOf = { s: new Map(), c: new Map() };
  for (const r of ROOTS) { keyOf.s.set(r, r); keyOf.c.set(r, r); }
  for (const [key, m] of Object.entries(mappings)) {
    const hs = m.s != null && S.byId.has(m.s);
    const hc = m.c != null && C.byId.has(m.c);
    if (!hs && !hc) { delete mappings[key]; continue; }
    if (hs) keyOf.s.set(m.s, key);
    if (hc) keyOf.c.set(m.c, key);
  }

  const nodes = {};
  for (const [key, m] of Object.entries(mappings)) {
    const prev = oldBase.nodes?.[key];
    const rs = m.s != null ? S.byId.get(m.s) : null;
    const rc = m.c != null ? C.byId.get(m.c) : null;
    if (!(rs && rc)) {
      if (prev) nodes[key] = prev; // alive on one side only (ignored delete): keep base as is
      continue;
    }
    const ps = rs.parentId ? keyOf.s.get(rs.parentId) ?? null : null;
    const pc = rc.parentId ? keyOf.c.get(rc.parentId) ?? null : null;
    const pick = (a, b, old) => (a === b ? a : old);
    const pickParent = (a, b, old) => (a != null && a === b ? a : old);
    nodes[key] = {
      kind: rs.kind,
      title: pick(rs.title, rc.title, prev?.title),
      url: rs.kind === 'bookmark' ? pick(rs.curl, rc.curl, prev?.url) : null,
      parent: pickParent(ps, pc, prev?.parent),
    };
  }

  const orders = {};
  const folderKeys = [...ROOTS, ...Object.keys(mappings)];
  for (const key of folderKeys) {
    const sid = isRoot(key) ? key : mappings[key]?.s;
    const cid = isRoot(key) ? key : mappings[key]?.c;
    const rs = sid != null ? S.byId.get(sid) : null;
    const rc = cid != null ? C.byId.get(cid) : null;
    if (!rs || !rc || rs.kind !== 'folder') { if (oldBase.orders?.[key]) orders[key] = oldBase.orders[key]; continue; }
    const sk = rs.children.map((id) => keyOf.s.get(id)).filter(Boolean);
    const ck = rc.children.map((id) => keyOf.c.get(id)).filter(Boolean);
    const cset = new Set(ck), sset = new Set(sk);
    const a = sk.filter((k) => cset.has(k)), b = ck.filter((k) => sset.has(k));
    const agree = a.length === b.length && a.every((k, i) => k === b[i]);
    orders[key] = agree ? a : oldBase.orders?.[key] || [];
  }

  return {
    ...state,
    version: 1,
    mappings,
    base: { nodes, orders },
    lastSyncAt: now,
  };
}
