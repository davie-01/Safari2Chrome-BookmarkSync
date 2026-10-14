// Multi-endpoint sync on top of the two-sided engine.
//
// Topology: hub-and-spoke. The hub holds the unified tree. Every endpoint E (Safari, each
// Chromium profile) is synced as a pair (s = hub, c = E) with its OWN base — the state hub
// and E last agreed on. An endpoint that was offline therefore never mistakes changes it
// missed for its own deletions.
//
// One run:
//   pass 1  for each online endpoint in order: diff(hub, E, baseE); apply the accepted
//           E-originated changes to a working copy of the hub
//   link    a conflict on E2 caused by a change another endpoint E1 made in this same run
//           is shown as ONE item (E1 vs E2); ignoring it also holds back E1's change
//   pass 2  for each endpoint: diff(hub', E, baseE) and write everything E still lacks.
//           Hub-originated changes are decisions already taken, so they propagate
//           automatically; choices that would write the hub are dropped (done in pass 1)
//
// Pair state per endpoint: { mappings: hubId -> { s: hubId, c: endpointNodeId }, base }.

import { computeDiff } from './diff.js';
import { buildPlan } from './plan.js';
import { commitSync } from './commit.js';
import { applyHubOps, cloneHub, emptyHub, hubFromBase, newHubId } from './hub.js';
import { ROOTS } from './util.js';

export const MODES = { both: 'both', receive: 's2c', send: 'c2s' };

const emptyPair = () => ({ mappings: {}, base: { nodes: {}, orders: {} } });

/** Which side an item originates from, in pair terms: 's' hub, 'c' endpoint, 'both'. */
export function originOf(it) {
  switch (it.type) {
    case 'modify':
    case 'create': return it.from;
    case 'delete':
    case 'deleteConflict': return it.deletedOn; // hub deleted -> 's'
    case 'conflict': return 'both';
    case 'order': return it.changedBy === 's' ? 's' : it.changedBy === 'c' ? 'c' : 'both';
    default: return 'both';
  }
}

const writesOf = (it, choice) => it.choices.find((c) => c.id === choice)?.writes;

/** Hub-originated, non-conflicting items are decisions already taken: propagate. */
function propagationChoice(it) {
  if (originOf(it) !== 's' || it.type === 'deleteConflict') return null;
  const want = it.type === 'order' ? 'useS' : 'apply';
  return it.choices.some((c) => c.id === want) ? want : null;
}

function isDecision(it) {
  const o = originOf(it);
  return o !== 's' || it.type === 'deleteConflict';
}

function subtreeIds(tree, id) {
  const out = [];
  const find = (n) => {
    if (n.id === id) { collect(n); return true; }
    return (n.children || []).some(find);
  };
  const collect = (n) => { out.push(n.id); (n.children || []).forEach(collect); };
  for (const r of ROOTS) if (find(tree.roots[r])) break;
  return out;
}

/**
 * @param {object} p
 * @param {object} p.hub         { tree, meta }
 * @param {Array}  p.endpoints   [{ id, name, mode, tree, pair, idGen? }] online + enabled, in processing order
 * @param {object} p.choices     user choices keyed by `${endpointId}|${itemId}` or `multi|conf:${key}`
 * @param {object} p.settings    { orderMaster, syncOrder }
 */
export function runMulti({ hub, endpoints, choices = {}, settings = {} }) {
  const groups = crossConflicts(hub, endpoints, settings);
  return passes(hub, endpoints, choices, groups, settings);
}

function pairOpts(E, settings) {
  return {
    direction: MODES[E.mode] || 'both',
    orderMaster: settings.orderMaster === E.id ? 'c' : 's',
  };
}

/**
 * Keys that two or more endpoints changed incompatibly since they last synced (same field,
 * different values, or delete vs modify). Found against the ORIGINAL hub, so the result does
 * not depend on processing order. Each becomes one decision: use endpoint X's version / ignore.
 */
function crossConflicts(hub, endpoints, settings) {
  const byKey = new Map(); // key -> Map(ep -> { fields: {f: v}, deleted, it })
  for (const E of endpoints) {
    if (MODES[E.mode] === 's2c') continue; // receive-only endpoints never send changes
    const d = computeDiff(E.pair || emptyPair(), hub.tree, E.tree, pairOpts(E, settings));
    const rec = (key) => {
      if (!byKey.has(key)) byKey.set(key, new Map());
      const m = byKey.get(key);
      if (!m.has(E.id)) m.set(E.id, { fields: {}, deleted: false, items: [] });
      return m.get(E.id);
    };
    for (const it of d.items) {
      if (it.type === 'modify' && it.from === 'c') {
        const r = rec(it.key);
        r.items.push(it);
        for (const f of it.fields) r.fields[f] = f === 'parent' ? it.c?.parentKey : f === 'url' ? it.c?.url : it.c?.title;
      } else if ((it.type === 'delete' || it.type === 'deleteConflict') && it.deletedOn === 'c') {
        const r = rec(it.key);
        r.items.push(it);
        r.deleted = true;
      }
    }
  }
  const groups = new Map();
  for (const [key, m] of byKey) {
    if (m.size < 2) continue;
    const eps = [...m.entries()];
    const anyDel = eps.some(([, r]) => r.deleted);
    const anyMod = eps.some(([, r]) => Object.keys(r.fields).length);
    let clash = anyDel && anyMod;
    if (!clash) {
      const fields = new Set(eps.flatMap(([, r]) => Object.keys(r.fields)));
      for (const f of fields) {
        const vals = new Set(eps.filter(([, r]) => f in r.fields).map(([, r]) => JSON.stringify(r.fields[f])));
        if (vals.size > 1) { clash = true; break; }
      }
    }
    if (clash) groups.set(key, { key, eps: eps.map(([ep, r]) => ({ ep, deleted: r.deleted, fields: r.fields, it: r.items[0] })) });
  }
  return groups;
}

/** Choice for an item that sits on a cross-endpoint conflict key. */
function groupChoice(it, E, winner) {
  if (winner === 'ignore') return 'ignore';
  if (E.id === winner) return originOf(it) === 'c' ? (it.choices.some((c) => c.id === 'apply') ? 'apply' : 'ignore') : propagationChoice(it) ?? 'ignore';
  if (it.type === 'conflict') return 'useS';
  if (it.type === 'deleteConflict') return it.deletedOn === 's' ? 'apply' : 'restore';
  if (originOf(it) === 's') return propagationChoice(it) ?? 'ignore';
  return 'ignore';
}

function passes(hub, endpoints, choices, groups, settings) {
  const sim = cloneHub(hub);
  const touched = new Map(); // hubId -> endpoint that changed it in this run
  const p1 = [];
  const warnings = [];
  const hubOps = [];
  const winnerOf = (key) => {
    const c = choices[`multi|conf:${key}`];
    return c && c.startsWith('use:') ? c.slice(4) : 'ignore';
  };
  const choose = (E, it, full, fallback) => {
    if (groups.has(it.key)) return groupChoice(it, E, winnerOf(it.key));
    return choices[full] ?? propagationChoice(it) ?? fallback(it);
  };

  for (const E of endpoints) {
    const d = computeDiff(E.pair || emptyPair(), sim.tree, E.tree, pairOpts(E, settings));
    const ch = {};
    for (const it of d.items) ch[it.id] = choose(E, it, `${E.id}|${it.id}`, (x) => x.default);
    const plan = buildPlan(d, ch, { syncOrder: settings.syncOrder !== false, idGen: { s: newHubId, c: E.idGen || null } });
    for (const w of d.warnings) warnings.push({ ...w, ep: E.id });
    for (const w of plan.warnings) warnings.push({ ...w, ep: E.id, pass: 1 });
    for (const op of plan.ops.s) {
      if (op.reorder) continue;
      const ids = op.op === 'remove' ? subtreeIds(sim.tree, op.id) : [op.id];
      for (const id of ids) if (!touched.has(id)) touched.set(id, E.id);
    }
    applyHubOps(sim, plan.ops.s, { by: E.id });
    hubOps.push(...plan.ops.s.map((o) => ({ ...o, ep: E.id })));
    p1.push({ E, d, ch });
  }

  // pass 2: what each endpoint still lacks
  const perEp = {};
  for (const { E, d, ch } of p1) {
    const d2 = computeDiff(E.pair || emptyPair(), sim.tree, E.tree, pairOpts(E, settings));
    const ch2 = {};
    for (const it of d2.items) {
      // same decision as in pass 1 (defaults included); only its endpoint-side writes remain
      let c = choose(E, it, `${E.id}|${it.id}`, (x) => ch[x.id] ?? 'ignore');
      if (writesOf(it, c) === 's') c = 'ignore';
      ch2[it.id] = c;
    }
    const plan2 = buildPlan(d2, ch2, { syncOrder: settings.syncOrder !== false, idGen: { s: null, c: E.idGen || null } });
    for (const w of plan2.warnings) if (w.code !== 'choiceNotAllowed') warnings.push({ ...w, ep: E.id, pass: 2 });
    perEp[E.id] = { d1: d, d2, plan2, ops: plan2.ops.c };
  }

  // decision list: pass-1 items (hub-originated propagations are not decisions) + one item per cross conflict
  const items = [];
  for (const { E, d, ch } of p1) {
    for (const it of d.items) {
      if (groups.has(it.key) || !isDecision(it)) continue;
      const by = touched.get(it.key) || hub.meta[it.key]?.by;
      items.push({ it, ep: E.id, full: `${E.id}|${it.id}`, choice: ch[it.id], against: by && by !== E.id ? by : null, diff: d });
    }
  }
  for (const g of groups.values()) {
    const first = p1.find((x) => x.E.id === g.eps[0].ep);
    items.push({ multi: g, full: `multi|conf:${g.key}`, choice: choices[`multi|conf:${g.key}`] || 'ignore', diff: first?.d });
  }

  const summary = {};
  for (const E of endpoints) {
    const ops = perEp[E.id].ops;
    const cnt = (k) => ops.filter((o) => o.op === k && !o.reorder).length;
    summary[E.id] = {
      create: cnt('create'), update: cnt('update'), move: cnt('move'), remove: cnt('remove'),
      reorderFolders: new Set(ops.filter((o) => o.reorder).map((o) => o.parent)).size,
      total: ops.length,
    };
  }
  summary.hub = { total: hubOps.length };

  return { hub: sim, hubOps, perEp, items, warnings, summary };
}

/** After execution: advance one endpoint's pair state, re-keyed to hub ids. */
export function commitEndpoint({ pair, perEp, hubTree, epTreeAfter, results, now = Date.now() }) {
  const st = commitSync({
    state: pair || emptyPair(),
    diff: perEp.d2,
    plan: perEp.plan2,
    results: { s: { applied: false }, c: results || {} },
    sTree: hubTree,
    cTree: epTreeAfter,
    now,
  });
  return rekey(st);
}

/** Re-key a pair state so every mapping key is its hub id (the stable identity). */
export function rekey(st) {
  const keyMap = new Map(ROOTS.map((r) => [r, r]));
  const mappings = {};
  for (const [k, m] of Object.entries(st.mappings || {})) {
    const nk = m.s ?? k;
    keyMap.set(k, nk);
    mappings[nk] = { ...m, ...(m.s ? { s: m.s } : {}) };
  }
  const mk = (k) => (k == null ? k : keyMap.get(k) ?? k);
  const nodes = {};
  for (const [k, n] of Object.entries(st.base?.nodes || {})) nodes[mk(k)] = { ...n, parent: mk(n.parent) };
  const orders = {};
  for (const [k, list] of Object.entries(st.base?.orders || {})) orders[mk(k)] = list.map(mk);
  return { mappings, base: { nodes, orders }, lastSyncAt: st.lastSyncAt };
}

// ---- persisted state ---------------------------------------------------------------

export function emptyState() {
  return { version: 2, hub: emptyHub(), endpoints: {} };
}

/**
 * v1 (one Safari<->Chrome pair, mappings key -> { s: safariUUID, c: chromeId }) -> v2.
 * The hub is rebuilt from the agreed base, so nothing pending is silently decided.
 */
export function migrateState(st) {
  if (!st) return emptyState();
  if (st.version === 2) return st;
  const base = st.base || { nodes: {}, orders: {} };
  const hub = hubFromBase(base);
  const pairFor = (side) => {
    const mappings = {};
    for (const [k, m] of Object.entries(st.mappings || {})) {
      if (!base.nodes?.[k]) continue; // never agreed: re-pair / re-offer instead of guessing
      mappings[k] = { s: k, ...(m[side] != null ? { c: m[side] } : {}) };
    }
    return { mappings, base: JSON.parse(JSON.stringify(base)) };
  };
  return {
    version: 2,
    hub,
    endpoints: { safari: { kind: 'safari', name: 'Safari', pair: pairFor('s') } },
    legacyChrome: { pair: pairFor('c') },
    migratedAt: Date.now(),
  };
}

/** Attach a newly seen endpoint; the first Chrome to connect adopts the v1 Chrome pair. */
export function adoptEndpoint(state, ep) {
  if (state.endpoints[ep.id]) return state.endpoints[ep.id];
  let pair = emptyPair();
  if (state.legacyChrome && ep.browser === 'chrome') {
    pair = state.legacyChrome.pair;
    delete state.legacyChrome;
  }
  state.endpoints[ep.id] = { kind: ep.kind || 'chromium', browser: ep.browser, name: ep.name, pair, firstSeenAt: Date.now() };
  return state.endpoints[ep.id];
}
