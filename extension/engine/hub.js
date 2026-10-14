// The hub: BookmarkSync's own copy of the bookmark tree, the "unified version" every
// endpoint (Safari, each Chromium profile) syncs against. Node ids are hub ids and never
// change; they double as the sync keys in each endpoint's pair state.

import { ROOTS } from './util.js';

export function emptyHub() {
  return {
    tree: { roots: { 'root:bar': { id: 'root:bar', kind: 'folder', title: '', children: [] }, 'root:other': { id: 'root:other', kind: 'folder', title: '', children: [] } } },
    meta: {}, // hubId -> { by: endpointId, at: ms } last endpoint whose change was accepted
  };
}

let seq = 0;
export function newHubId() {
  const c = globalThis.crypto;
  const r = c && typeof c.randomUUID === 'function'
    ? c.randomUUID().replace(/-/g, '').toLowerCase()
    : `${Date.now().toString(36)}${(seq++).toString(36)}${Math.random().toString(36).slice(2, 8)}`;
  return `h${r}`;
}

export function cloneHub(h) { return JSON.parse(JSON.stringify(h)); }

function index(tree) {
  const byId = new Map();
  const parentOf = new Map();
  const walk = (n, p) => {
    byId.set(n.id, n);
    if (p) parentOf.set(n.id, p);
    for (const ch of n.children || []) walk(ch, n);
  };
  for (const r of ROOTS) walk(tree.roots[r], null);
  return { byId, parentOf };
}

/** Apply engine wire ops (side 's' of a pair whose s side is the hub). Throws on precondition failure. */
export function applyHubOps(hub, ops, { by = null, at = Date.now() } = {}) {
  const { byId, parentOf } = index(hub.tree);
  const insert = (parent, node, after) => {
    if (!parent || parent.kind !== 'folder') throw new Error('hub: parent missing');
    parent.children ??= [];
    if (after === 'END' || after === undefined) parent.children.push(node);
    else if (after === null) parent.children.unshift(node);
    else {
      const i = parent.children.findIndex((c) => c.id === after);
      if (i < 0) throw new Error('hub: anchor missing');
      parent.children.splice(i + 1, 0, node);
    }
    parentOf.set(node.id, parent);
  };
  const touch = (id) => { if (by) hub.meta[id] = { by, at }; };
  for (const op of ops) {
    switch (op.op) {
      case 'create': {
        if (!op.id || byId.has(op.id)) throw new Error('hub: bad create id');
        const node = op.kind === 'folder'
          ? { id: op.id, kind: 'folder', title: op.title ?? '', children: [] }
          : { id: op.id, kind: 'bookmark', title: op.title ?? '', url: op.url ?? '' };
        insert(byId.get(op.parent), node, op.after);
        byId.set(op.id, node);
        touch(op.id);
        break;
      }
      case 'update': {
        const n = byId.get(op.id);
        if (!n) throw new Error('hub: update missing');
        if (op.title !== undefined) n.title = op.title;
        if (op.url !== undefined) n.url = op.url;
        touch(op.id);
        break;
      }
      case 'move': {
        const n = byId.get(op.id);
        const p = parentOf.get(op.id);
        const dest = byId.get(op.parent);
        if (!n || !p || !dest) throw new Error('hub: move missing');
        for (let cur = dest; cur; cur = parentOf.get(cur.id)) if (cur.id === op.id) throw new Error('hub: cycle');
        p.children = p.children.filter((c) => c.id !== op.id);
        insert(dest, n, op.after);
        if (!op.reorder) touch(op.id);
        break;
      }
      case 'remove': {
        const p = parentOf.get(op.id);
        if (!p) throw new Error('hub: remove missing');
        p.children = p.children.filter((c) => c.id !== op.id);
        const stack = [byId.get(op.id)];
        while (stack.length) {
          const x = stack.pop();
          byId.delete(x.id);
          delete hub.meta[x.id];
          stack.push(...(x.children || []));
        }
        break;
      }
      default: throw new Error(`hub: unknown op ${op.op}`);
    }
  }
  return hub;
}

/** Rebuild a hub from a v1 base ({nodes, orders} keyed by sync key). */
export function hubFromBase(base) {
  const hub = emptyHub();
  const nodes = base?.nodes || {};
  const orders = base?.orders || {};
  const kids = new Map();
  for (const [key, n] of Object.entries(nodes)) {
    if (!n || !n.parent) continue;
    if (!kids.has(n.parent)) kids.set(n.parent, []);
    kids.get(n.parent).push(key);
  }
  const build = (key, depth) => {
    const n = nodes[key];
    const node = n.kind === 'folder'
      ? { id: key, kind: 'folder', title: n.title ?? '', children: [] }
      : { id: key, kind: 'bookmark', title: n.title ?? '', url: n.url ?? '' };
    if (n.kind === 'folder' && depth < 64) node.children = orderedChildren(key).map((k) => build(k, depth + 1));
    return node;
  };
  const orderedChildren = (parent) => {
    const all = kids.get(parent) || [];
    const set = new Set(all);
    const ord = (orders[parent] || []).filter((k) => set.has(k));
    const rest = all.filter((k) => !ord.includes(k));
    return [...ord, ...rest];
  };
  for (const r of ROOTS) hub.tree.roots[r].children = orderedChildren(r).map((k) => build(k, 0));
  return hub;
}
