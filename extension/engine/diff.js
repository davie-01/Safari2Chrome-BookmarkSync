// Three-way diff between the last agreed base, current Safari tree and current Chrome tree.
//
// Identity: every synced node has a *key*. The mapping key -> {s: safariUUID, c: chromeId}
// is persisted. URLs are never identity, only matching evidence.
//
// Pipeline:
//   1. bind current ids to keys via mapping
//   2. re-identify nodes whose side id vanished (Safari/iCloud UUID rebuilds) — only on
//      unambiguous evidence; otherwise the node is treated as missing, and deletes are
//      never applied by default anyway
//   3. pair up unmapped nodes that sit in the same mapped folder on both sides and look
//      identical (first sync / same bookmark added on both sides) — keeps duplicates
//   4. classify every key: modified on one side, conflicting, deleted on one side,
//      new on one side
//
// Output items carry every allowed choice and a default; buildPlan() turns choices into ops.

import { buildIndex, descendants, pathOf } from './tree.js';
import { ROOTS, ROOT_TITLES, isRoot, other, lcsSet, sameOrder } from './util.js';

export const FIELDS = ['title', 'url', 'parent'];

export function computeDiff(state, sTree, cTree, opts = {}) {
  const direction = opts.direction || 'both'; // 'both' | 's2c' | 'c2s'
  const idx = { s: buildIndex(sTree), c: buildIndex(cTree) };
  const mappings = state?.mappings || {};
  const baseNodes = state?.base?.nodes || {};
  const baseOrders = state?.base?.orders || {};

  const keyOf = { s: new Map(), c: new Map() };
  const idOf = { s: new Map(), c: new Map() };
  const bind = (side, key, id) => { keyOf[side].set(id, key); idOf[side].set(key, id); };
  for (const r of ROOTS) { bind('s', r, r); bind('c', r, r); }

  const staleIds = []; // mapping ids that no longer exist
  for (const [key, m] of Object.entries(mappings)) {
    for (const side of ['s', 'c']) {
      const id = m[side];
      if (id == null) continue;
      if (idx[side].byId.has(id) && !keyOf[side].has(id) && !idOf[side].has(key)) bind(side, key, id);
      else staleIds.push({ side, key, id });
    }
  }

  // ---- 2. re-identification -------------------------------------------------
  const rebinds = [];
  const depthOfBase = (key) => {
    let d = 0, cur = baseNodes[key];
    const seen = new Set();
    while (cur && cur.parent && !isRoot(cur.parent) && !seen.has(cur.parent)) {
      seen.add(cur.parent); d++; cur = baseNodes[cur.parent];
    }
    return d;
  };
  for (const side of ['s', 'c']) {
    const missing = Object.keys(mappings)
      .filter((k) => mappings[k][side] != null && !idOf[side].has(k) && baseNodes[k])
      .sort((a, b) => depthOfBase(a) - depthOfBase(b));
    let progress = true;
    let remaining = missing;
    for (let pass = 0; pass < 3 && progress && remaining.length; pass++) {
      progress = false;
      const next = [];
      for (const key of remaining) {
        const b = baseNodes[key];
        const cands = [];
        for (const [id, rec] of idx[side].byId) {
          if (keyOf[side].has(id) || rec.kind !== b.kind) continue;
          const pk = rec.parentId ? keyOf[side].get(rec.parentId) : undefined;
          if (b.kind === 'bookmark') {
            if (rec.title === b.title && rec.curl === b.url && pk === b.parent) cands.push(id);
          } else {
            const mappedKids = rec.children.map((c) => keyOf[side].get(c)).filter(Boolean);
            const evidence = mappedKids.filter((k) => baseNodes[k]?.parent === key).length;
            const strong = evidence >= 2 && evidence === mappedKids.length;
            const titleOk = rec.title === b.title;
            if ((titleOk && pk === b.parent) || (titleOk && evidence > 0) || strong) cands.push(id);
          }
        }
        if (cands.length === 1) {
          bind(side, key, cands[0]);
          rebinds.push({ side, key, from: mappings[key][side], to: cands[0] });
          progress = true;
        } else next.push(key);
      }
      remaining = next;
    }
  }

  // ---- 3. pairing of unmapped nodes -----------------------------------------
  const pairs = [];
  const queue = [];
  for (const [key, sid] of idOf.s) {
    const cid = idOf.c.get(key);
    if (cid != null && idx.s.byId.get(sid).kind === 'folder' && idx.c.byId.get(cid).kind === 'folder') queue.push(key);
  }
  const usedKeys = new Set([...Object.keys(mappings), ...ROOTS]);
  const freshKey = (side, id) => {
    let k = `${side}:${id}`, n = 1;
    while (usedKeys.has(k)) k = `${side}:${id}#${n++}`;
    usedKeys.add(k);
    return k;
  };
  while (queue.length) {
    const F = queue.shift();
    const sRec = idx.s.byId.get(idOf.s.get(F));
    const cRec = idx.c.byId.get(idOf.c.get(F));
    let sUn = sRec.children.filter((id) => !keyOf.s.has(id));
    let cUn = cRec.children.filter((id) => !keyOf.c.has(id));
    if (!sUn.length || !cUn.length) continue;
    const passes = [
      (r) => `${r.kind}\u0000${r.title}\u0000${r.curl ?? ''}`,
      (r) => (r.kind === 'bookmark' ? `u\u0000${r.curl}` : null),
    ];
    for (const sig of passes) {
      const bucket = new Map();
      for (const cid of cUn) {
        const k = sig(idx.c.byId.get(cid));
        if (k == null) continue;
        if (!bucket.has(k)) bucket.set(k, []);
        bucket.get(k).push(cid);
      }
      const usedC = new Set();
      const restS = [];
      for (const sid of sUn) {
        const k = sig(idx.s.byId.get(sid));
        const list = k == null ? null : bucket.get(k);
        if (list && list.length) {
          const cid = list.shift();
          usedC.add(cid);
          const key = freshKey('s', sid);
          bind('s', key, sid); bind('c', key, cid);
          pairs.push({ key, s: sid, c: cid });
          if (idx.s.byId.get(sid).kind === 'folder') queue.push(key);
        } else restS.push(sid);
      }
      sUn = restS;
      cUn = cUn.filter((c) => !usedC.has(c));
      if (!sUn.length || !cUn.length) break;
    }
  }

  // ---- remaining unmapped nodes get deterministic keys -----------------------
  const isNew = { s: new Set(), c: new Set() };
  for (const side of ['s', 'c']) {
    for (const id of idx[side].byId.keys()) {
      if (!keyOf[side].has(id)) { bind(side, freshKey(side, id), id); isNew[side].add(id); }
    }
  }

  // ---- helpers ----------------------------------------------------------------
  const rec = (side, key) => idx[side].byId.get(idOf[side].get(key));
  const has = (side, key) => idOf[side].has(key);
  const parentKey = (side, key) => {
    const r = rec(side, key);
    return r && r.parentId ? keyOf[side].get(r.parentId) : null;
  };
  const value = (side, key, f) => {
    const r = rec(side, key);
    if (f === 'title') return r.title;
    if (f === 'url') return r.curl;
    return parentKey(side, key);
  };
  const parentGoneOnOther = (side, key) => {
    const pk = parentKey(side, key);
    if (!pk || isRoot(pk) || has(other(side), pk)) return false;
    return !isNew[side].has(idOf[side].get(pk));
  };
  const changed = (side, key) => {
    const b = baseNodes[key];
    if (!b) return { title: true, url: true, parent: true };
    const r = rec(side, key);
    return {
      title: r.title !== b.title,
      url: r.kind === 'bookmark' && r.curl !== b.url,
      parent: parentKey(side, key) !== b.parent,
    };
  };
  const anyChanged = (side, key) => {
    const ch = changed(side, key);
    return ch.title || ch.url || ch.parent;
  };
  const subtreeDirty = (side, key) => {
    if (!baseNodes[key] || anyChanged(side, key)) return true;
    for (const d of descendants(idx[side], idOf[side].get(key))) {
      if (isNew[side].has(d)) return true;
      const k = keyOf[side].get(d);
      if (!baseNodes[k] || anyChanged(side, k)) return true;
    }
    return false;
  };
  const rootTitle = (id) => ROOT_TITLES[id] || id;
  const info = (side, key) => {
    const r = rec(side, key);
    if (!r) return null;
    return {
      id: r.id,
      title: r.title,
      url: r.url,
      path: pathOf(idx[side], r.id, rootTitle),
      parentKey: parentKey(side, key),
    };
  };
  const subtreeCount = (side, key) => {
    let n = 1;
    for (const _ of descendants(idx[side], idOf[side].get(key))) n++;
    return n;
  };

  // ---- 4. classify -------------------------------------------------------------
  const items = [];
  const dropKeys = [];
  const src = direction === 's2c' ? 's' : direction === 'c2s' ? 'c' : null;
  const allowed = (writes) => !src || writes === other(src);

  const push = (item) => {
    // choices: [{ id, writes }] ; filter by direction
    item.choices = item.choices.filter((c) => c.id === 'ignore' || allowed(c.writes));
    if (!item.choices.some((c) => c.id === item.default)) item.default = 'ignore';
    items.push(item);
  };

  const mappedKeys = new Set([...Object.keys(mappings), ...pairs.map((p) => p.key)]);
  for (const key of mappedKeys) {
    const hs = has('s', key), hc = has('c', key);
    const b = baseNodes[key];
    if (!hs && !hc) { dropKeys.push(key); continue; }
    const kind = (rec('s', key) || rec('c', key)).kind;

    if (hs && hc) {
      const chS = changed('s', key), chC = changed('c', key);
      const s2c = [], c2s = [], conf = [];
      for (const f of FIELDS) {
        if (f === 'url' && kind !== 'bookmark') continue;
        if (value('s', key, f) === value('c', key, f)) continue;
        // moved into a folder that the other side deleted: handled by that folder's delete item
        if (f === 'parent' && (parentGoneOnOther('s', key) || parentGoneOnOther('c', key))) continue;
        if (b && chS[f] && !chC[f]) s2c.push(f);
        else if (b && chC[f] && !chS[f]) c2s.push(f);
        else conf.push(f);
      }
      const base = { key, kind, s: info('s', key), c: info('c', key), b: b || null };
      if (s2c.length) push({ ...base, id: `mod:s:${key}`, type: 'modify', from: 's', fields: s2c,
        choices: [{ id: 'apply', writes: 'c' }, { id: 'revert', writes: 's' }, { id: 'ignore' }],
        default: !src || src === 's' ? 'apply' : 'ignore' });
      if (c2s.length) push({ ...base, id: `mod:c:${key}`, type: 'modify', from: 'c', fields: c2s,
        choices: [{ id: 'apply', writes: 's' }, { id: 'revert', writes: 'c' }, { id: 'ignore' }],
        default: !src || src === 'c' ? 'apply' : 'ignore' });
      if (conf.length) push({ ...base, id: `conf:${key}`, type: 'conflict', fields: conf, firstSync: !b,
        choices: [{ id: 'useS', writes: 'c' }, { id: 'useC', writes: 's' }, { id: 'ignore' }],
        default: src === 's' ? 'useS' : src === 'c' ? 'useC' : 'ignore' });
      continue;
    }

    // present on exactly one side
    const alive = hs ? 's' : 'c';
    const gone = other(alive);
    const pk = parentKey(alive, key);
    // covered by an ancestor that is also gone on the other side
    if (pk && !isRoot(pk) && !isNew[alive].has(idOf[alive].get(pk)) && !has(gone, pk)) continue;
    const dirty = subtreeDirty(alive, key);
    push({
      id: `del:${gone}:${key}`,
      type: dirty ? 'deleteConflict' : 'delete',
      key, kind,
      deletedOn: gone,
      [alive]: info(alive, key),
      b: b || null,
      count: subtreeCount(alive, key),
      choices: [{ id: 'apply', writes: alive }, { id: 'restore', writes: gone }, { id: 'ignore' }],
      default: 'ignore', // deletions are never pre-selected
    });
  }

  for (const side of ['s', 'c']) {
    for (const id of isNew[side]) {
      const r = idx[side].byId.get(id);
      const pk = keyOf[side].get(r.parentId);
      if (isNew[side].has(r.parentId)) continue; // inside a new subtree
      if (!has(other(side), pk)) continue; // parent gone on the other side -> covered by delete item
      const key = keyOf[side].get(id);
      push({
        id: `new:${side}:${id}`,
        type: 'create',
        key, kind: r.kind,
        from: side,
        [side]: info(side, key),
        count: subtreeCount(side, key),
        choices: [{ id: 'apply', writes: other(side) }, { id: 'remove', writes: side }, { id: 'ignore' }],
        default: !src || src === side ? 'apply' : 'ignore',
      });
    }
  }

  // ---- sibling order ---------------------------------------------------------
  // One 'order' item per folder whose common children are in a different order on the
  // two sides. Which side "changed" is judged against the agreed base order; a change that
  // moves many items at once (system re-sort, iCloud merge, sort-by-name) is flagged as
  // suspicious and never applied automatically. Default: the side the user changed, or the
  // configured master side (Chrome by default) when unclear.
  const master = opts.orderMaster === 's' ? 's' : 'c';
  const foldersBoth = [...ROOTS, ...[...mappedKeys].filter((k) => has('s', k) && has('c', k) && rec('s', k).kind === 'folder')];
  for (const F of foldersBoth) {
    const sKids = rec('s', F).children.map((id) => keyOf.s.get(id));
    const cKids = rec('c', F).children.map((id) => keyOf.c.get(id));
    const cSet = new Set(cKids);
    const common = new Set(sKids.filter((k) => cSet.has(k)));
    if (common.size < 2) continue;
    const sOrd = sKids.filter((k) => common.has(k));
    const cOrd = cKids.filter((k) => common.has(k));
    if (sameOrder(sOrd, cOrd)) continue;
    const bOrd = (baseOrders[F] || []).filter((k) => common.has(k));
    const moved = (list) => {
      const b = bOrd.filter((k) => list.includes(k));
      const l = list.filter((k) => b.includes(k));
      return b.length < 2 ? null : l.length - lcsSet(l, b).size;
    };
    const mS = moved(sOrd), mC = moved(cOrd);
    const big = (m) => m !== null && m >= 3 && m / common.size > 0.3;
    let changedBy = null;
    if (mS && !mC) changedBy = 's';
    else if (mC && !mS) changedBy = 'c';
    else if (mS && mC) changedBy = 'both';
    const suspicious = (changedBy === 's' && big(mS)) || (changedBy === 'c' && big(mC)) || (changedBy === 'both');
    let def;
    if (changedBy === 's' || changedBy === 'c') def = suspicious ? (master === 's' ? 'useS' : 'useC') : (changedBy === 's' ? 'useS' : 'useC');
    else def = master === 's' ? 'useS' : 'useC';
    const titleOf = (side, list) => list.map((k) => rec(side, k)?.title ?? '');
    push({
      id: `order:${F}`,
      type: 'order',
      key: F,
      kind: 'folder',
      changedBy,
      suspicious,
      firstSync: bOrd.length < 2,
      moved: { s: mS, c: mC },
      count: common.size,
      s: { ...(isRoot(F) ? { id: F, title: rootTitle(F), path: '' } : info('s', F)), order: titleOf('s', sOrd) },
      c: { ...(isRoot(F) ? { id: F, title: rootTitle(F), path: '' } : info('c', F)), order: titleOf('c', cOrd) },
      choices: [{ id: 'useS', writes: 'c' }, { id: 'useC', writes: 's' }, { id: 'ignore' }],
      default: def,
    });
  }

  // ---- safety signals ------------------------------------------------------
  const warnings = [];
  const mappedCount = Object.keys(mappings).length;
  for (const side of ['s', 'c']) {
    const gone = Object.keys(mappings).filter((k) => !has(side, k)).length;
    if (mappedCount >= 10 && gone / mappedCount > 0.3) {
      warnings.push({ code: 'massMissing', side, gone, total: mappedCount });
    }
  }

  items.sort((a, b) => itemSortKey(a).localeCompare(itemSortKey(b), 'zh'));

  return {
    direction,
    items,
    warnings,
    stats: {
      s: { nodes: idx.s.byId.size - ROOTS.length, ignored: idx.s.ignored },
      c: { nodes: idx.c.byId.size - ROOTS.length, ignored: idx.c.ignored },
      mapped: mappedKeys.size,
      pairs: pairs.length,
      rebinds: rebinds.length,
    },
    ctx: { idx, keyOf, idOf, isNew, pairs, rebinds, dropKeys, baseNodes, baseOrders, staleIds },
  };
}

function itemSortKey(it) {
  const inf = it.s || it.c;
  return `${inf?.path ?? ''}/${inf?.title ?? ''}`;
}
