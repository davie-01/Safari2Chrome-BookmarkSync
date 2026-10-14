// Turn diff items + user choices into concrete, ordered per-side operations.
//
// Op (engine form, key based):
//   create { key, kind, title, url?, parent: key, after: 'END'|null|key }
//   update { key, title?, url? }
//   move   { key, parent: key, after: 'END'|null|key }
//   remove { key }
// Every op is validated against an in-memory simulation of the target side; ops that
// cannot be applied (missing parent, unsafe removal, ...) are dropped with a warning.
//
// Execution order per side: creates -> moves -> updates -> removes -> reorders.

import { SimTree, SimError, descendants } from './tree.js';
import { isRoot, lcsSet, newSafariUUID, other, sameOrder } from './util.js';

export function buildPlan(diff, choices = {}, opts = {}) {
  const { idx, keyOf, idOf, isNew, baseOrders, baseNodes } = diff.ctx;
  const direction = diff.direction;
  const src = direction === 's2c' ? 's' : direction === 'c2s' ? 'c' : null;
  const writable = { s: !src || src === 'c', c: !src || src === 's' };
  const syncOrder = opts.syncOrder !== false;
  // Id generators for new nodes per side. null = the executor assigns ids (Chrome API).
  const idGen = {
    s: opts.idGen?.s !== undefined ? opts.idGen.s : (opts.newSafariId || newSafariUUID),
    c: opts.idGen?.c !== undefined ? opts.idGen.c : null,
  };

  const sim = {
    s: SimTree.fromIndex(idx.s, (id) => keyOf.s.get(id)),
    c: SimTree.fromIndex(idx.c, (id) => keyOf.c.get(id)),
  };
  const buckets = { s: mkBuckets(), c: mkBuckets() };
  const warnings = [];
  const appliedItems = [];
  const orderChoice = {}; // folder key -> useS | useC

  const rec = (side, key) => idx[side].byId.get(idOf[side].get(key));
  const parentKey = (side, key) => {
    const r = rec(side, key);
    return r && r.parentId ? keyOf[side].get(r.parentId) : null;
  };

  const writeFields = (target, valueSide, key, fields, item) => {
    const r = rec(valueSide, key);
    const upd = { op: 'update', key, item: item.id };
    let any = false;
    for (const f of fields) {
      if (f === 'title') { upd.title = r.title; any = true; }
      else if (f === 'url') { upd.url = r.url; any = true; }
      else if (f === 'parent') {
        buckets[target].moves.push({ op: 'move', key, parent: parentKey(valueSide, key), after: 'END', item: item.id });
      }
    }
    if (!any) return;
    // one update per node and side, so preconditions refer to the scanned state
    const prev = buckets[target].updates.find((u) => u.key === key);
    if (prev) {
      if (upd.title !== undefined) prev.title = upd.title;
      if (upd.url !== undefined) prev.url = upd.url;
    } else buckets[target].updates.push(upd);
  };

  // Recreate the subtree rooted at `key` from `fromSide` onto `target`.
  // Children that still exist on the target elsewhere are skipped (they were moved out).
  const createSubtree = (target, fromSide, key, item, includeMapped) => {
    const walk = (id, parentKeyOnTarget, isTop) => {
      const r = idx[fromSide].byId.get(id);
      const k = keyOf[fromSide].get(id);
      if (idOf[target].has(k)) {
        // exists on target elsewhere: pull it into the recreated folder unless the target moved it itself
        if (!isTop && includeMapped && baseNodes[k] && parentKey(target, k) === baseNodes[k].parent) {
          buckets[target].moves.push({ op: 'move', key: k, parent: parentKeyOnTarget, after: 'END', item: item.id });
        }
        return;
      }
      if (!includeMapped && !isNew[fromSide].has(id)) return;
      buckets[target].creates.push({
        pre: r.pre,
        op: 'create', key: k, kind: r.kind, title: r.title,
        ...(r.kind === 'bookmark' ? { url: r.url } : {}),
        parent: parentKeyOnTarget, after: 'END', item: item.id,
      });
      for (const ch of r.children) walk(ch, k, false);
    };
    walk(idOf[fromSide].get(key), parentKey(fromSide, key), true);
  };

  for (const item of diff.items) {
    const choice = choices[item.id] ?? item.default;
    if (item.type === 'order' && choice === 'ignore') { orderChoice[item.key] = 'ignore'; continue; }
    if (!choice || choice === 'ignore') continue;
    const allowed = item.choices.find((c) => c.id === choice);
    if (!allowed) { warnings.push({ code: 'choiceNotAllowed', item: item.id, choice }); continue; }
    appliedItems.push(item.id);
    switch (item.type) {
      case 'modify': {
        const from = item.from, to = other(from);
        if (choice === 'apply') writeFields(to, from, item.key, item.fields, item);
        else if (choice === 'revert') writeFields(from, to, item.key, item.fields, item);
        break;
      }
      case 'conflict': {
        if (choice === 'useS') writeFields('c', 's', item.key, item.fields, item);
        else if (choice === 'useC') writeFields('s', 'c', item.key, item.fields, item);
        break;
      }
      case 'create': {
        const from = item.from;
        if (choice === 'apply') createSubtree(other(from), from, item.key, item, false);
        else if (choice === 'remove') buckets[from].removes.push({ op: 'remove', key: item.key, item: item.id });
        break;
      }
      case 'delete':
      case 'deleteConflict': {
        const alive = other(item.deletedOn);
        if (choice === 'apply') buckets[alive].removes.push({ op: 'remove', key: item.key, item: item.id });
        else if (choice === 'restore') createSubtree(item.deletedOn, alive, item.key, item, true);
        break;
      }
      case 'order':
        orderChoice[item.key] = choice;
        break;
      default:
        warnings.push({ code: 'unknownItemType', item: item.id });
    }
  }

  const out = { s: [], c: [] };
  const failed = new Set();
  for (const side of ['s', 'c']) {
    const t = sim[side];
    const b = buckets[side];
    const otherIdOf = idOf[other(side)];
    const tryApply = (op) => {
      try { t.apply(op); out[side].push(op); return true; }
      catch (e) {
        if (!(e instanceof SimError)) throw e;
        warnings.push({ code: 'opDropped', side, op: op.op, key: op.key, item: op.item, reason: e.message });
        failed.add(op.item);
        return false;
      }
    };
    // creates: in source-tree order (never in the diff list's display order), parents first
    let pending = [...b.creates].sort((x, y) => x.pre - y.pre);
    for (let guard = 0; pending.length && guard < 1000; guard++) {
      const next = pending.filter((op) => {
        if (!t.has(op.parent)) return true;
        tryApply(op);
        return false;
      });
      if (next.length === pending.length) break;
      pending = next;
    }
    for (const op of pending) {
      warnings.push({ code: 'parentMissing', side, key: op.key, item: op.item });
      failed.add(op.item);
    }
    for (const op of b.moves) tryApply(op);
    for (const op of b.updates) tryApply(op);
    for (const op of b.removes) {
      if (!t.has(op.key)) continue; // already gone with an ancestor
      // never destroy a node that is alive on the other side (and was moved out there)
      const sub = new Set(t.subtreeKeys(op.key));
      let keep = [...sub].filter((k) => k !== op.key && otherIdOf.has(k));
      // relocate survivors to where the other side has them, if that place exists here
      const relocations = [];
      for (const k of keep) {
        if (keep.some((a) => a !== k && t.isAncestor(a, k))) continue; // moves with its ancestor
        const dest = parentKey(other(side), k);
        if (dest && t.has(dest) && !sub.has(dest)) relocations.push({ op: 'move', key: k, parent: dest, after: 'END', item: op.item });
        else relocations.push(null);
      }
      if (!relocations.includes(null)) {
        for (const mv of relocations) tryApply(mv);
        keep = t.subtreeKeys(op.key).filter((k) => k !== op.key && otherIdOf.has(k));
      }
      if (keep.length) {
        warnings.push({ code: 'unsafeRemove', side, key: op.key, item: op.item, keep: keep.length });
        failed.add(op.item);
        continue;
      }
      tryApply(op);
    }
  }

  // ---- ordering pass --------------------------------------------------------
  const reorders = { s: [], c: [] };
  const inserted = { s: new Set(), c: new Set() };
  for (const side of ['s', 'c']) {
    for (const op of out[side]) if (op.op === 'create' || op.op === 'move') inserted[side].add(`${op.parent}\u0000${op.key}`);
  }
  if (syncOrder) {
    for (const [F, sn] of sim.s.nodes) {
      if (sn.kind !== 'folder') continue;
      const cn = sim.c.get(F);
      if (!cn || cn.kind !== 'folder') continue;
      const sK = sn.children, cK = cn.children;
      // useS / useC: one side's order wins for common children; new items are placed after
      // their predecessor from wherever they came from. Otherwise ('ignore', or the orders
      // already agree): every side keeps its own order and only new items get positioned.
      let choice = orderChoice[F];
      if (src && choice && choice !== 'ignore') choice = src === 's' ? 'useS' : 'useC';
      // Items this plan put into F on a side sit at the end there; take their position
      // from the side they came from instead.
      const sB = sK.filter((k) => !inserted.s.has(`${F}\u0000${k}`));
      const cB = cK.filter((k) => !inserted.c.has(`${F}\u0000${k}`));
      let merged;
      if (choice === 'ignore') merged = { s: mergeOrder(sB, cB), c: mergeOrder(cB, sB) };
      else {
        const M = choice === 'useS' ? mergeOrder(sB, cB) : mergeOrder(cB, sB);
        merged = { s: M, c: M };
      }
      for (const side of ['s', 'c']) {
        if (!writable[side]) continue;
        const node = sim[side].get(F);
        const present = new Set(node.children);
        const desired = merged[side].filter((k) => present.has(k));
        if (sameOrder(desired, node.children)) continue;
        const keepSet = lcsSet(node.children, desired);
        desired.forEach((k, i) => {
          if (keepSet.has(k)) return;
          const op = { op: 'move', key: k, parent: F, after: i === 0 ? null : desired[i - 1], item: `order:${F}`, reorder: true };
          sim[side].apply(op);
          reorders[side].push(op);
        });
      }
    }
  }
  for (const side of ['s', 'c']) out[side].push(...reorders[side]);

  // ---- resolve to side ids ---------------------------------------------------
  const created = { s: new Map(), c: new Map() };
  const wire = { s: [], c: [] };
  for (const side of ['s', 'c']) {
    if (idGen[side]) for (const op of out[side]) if (op.op === 'create') created[side].set(op.key, idGen[side](op.key));
    const ref = (key) => {
      if (key === null || key === 'END' || key === undefined) return key;
      if (isRoot(key)) return key;
      return idOf[side].get(key) ?? created[side].get(key) ?? { key };
    };
    for (const op of out[side]) {
      const w = { op: op.op, key: op.key };
      if (op.op === 'create') {
        if (created[side].has(op.key)) w.id = created[side].get(op.key);
        Object.assign(w, { kind: op.kind, title: op.title, parent: ref(op.parent), after: ref(op.after) });
        if (op.kind === 'bookmark') w.url = op.url;
      } else {
        w.id = ref(op.key);
        const r = idOf[side].has(op.key) ? idx[side].byId.get(idOf[side].get(op.key)) : null;
        if (op.op === 'update') {
          if (op.title !== undefined) w.title = op.title;
          if (op.url !== undefined) w.url = op.url;
          if (r) w.expect = { title: r.title, ...(r.kind === 'bookmark' ? { url: r.url } : {}) };
        } else if (op.op === 'move') {
          w.parent = ref(op.parent);
          w.after = ref(op.after);
          if (op.reorder) w.reorder = true;
        } else if (op.op === 'remove') {
          if (r) w.expect = { kind: r.kind, title: r.title, ...(r.kind === 'bookmark' ? { url: r.url } : {}) };
        }
      }
      w.item = op.item;
      wire[side].push(w);
    }
  }

  const count = (side, kind) => out[side].filter((o) => o.op === kind && !o.reorder).length;
  const summary = {};
  for (const side of ['s', 'c']) {
    summary[side] = {
      create: count(side, 'create'),
      update: count(side, 'update'),
      move: count(side, 'move'),
      remove: count(side, 'remove'),
      removeNodes: 0,
      reorderFolders: new Set(reorders[side].map((o) => o.parent)).size,
      total: out[side].length,
    };
  }
  // how many nodes disappear because of removes (subtrees)
  for (const side of ['s', 'c']) {
    const before = idx[side].byId.size;
    summary[side].removeNodes = Math.max(0, before - sim[side].nodes.size + summary[side].create);
  }

  return {
    direction,
    ops: wire,
    summary,
    warnings,
    appliedItems: appliedItems.filter((id) => !failed.has(id)),
    failedItems: [...failed],
    expected: sim,
    safariCreated: Object.fromEntries(created.s),
    createdIds: { s: Object.fromEntries(created.s), c: Object.fromEntries(created.c) },
  };
}

function mkBuckets() {
  return { creates: [], moves: [], updates: [], removes: [] };
}

/** primary order first; items only in `secondary` are inserted after their nearest predecessor. */
export function mergeOrder(primary, secondary) {
  const M = [...primary];
  const inM = new Set(M);
  let lastAnchor = null;
  for (const k of secondary) {
    if (inM.has(k)) { lastAnchor = k; continue; }
    const pos = lastAnchor === null ? 0 : M.indexOf(lastAnchor) + 1;
    M.splice(pos, 0, k);
    inM.add(k);
    lastAnchor = k;
  }
  return M;
}

export { descendants };
