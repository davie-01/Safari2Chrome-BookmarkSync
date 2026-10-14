// Normalized tree indexing + an in-memory simulator that applies plan ops with the
// same semantics as the real executors (Chrome extension, Safari agent).
//
// Normalized tree (from either adapter):
//   { roots: { 'root:bar': Node, 'root:other': Node } }
//   Node = { id, kind: 'folder'|'bookmark'|'special', title, url?, children?: Node[], readonly? }
// Root nodes carry id === root key. 'special' / readonly nodes are ignored by the engine
// (never synced, never touched), and they are invisible for ordering purposes.

import { ROOTS, canonUrl } from './util.js';

export function buildIndex(tree) {
  const byId = new Map();
  let ignored = 0;
  let pre = 0;
  const walk = (node, parentId, depth) => {
    const kids = [];
    const rec = {
      id: node.id,
      kind: node.kind,
      title: node.title ?? '',
      url: node.kind === 'bookmark' ? (node.url ?? '') : null,
      curl: node.kind === 'bookmark' ? canonUrl(node.url ?? '') : null,
      parentId,
      depth,
      index: 0,
      pre: pre++,
      children: kids,
    };
    byId.set(node.id, rec);
    for (const ch of node.children || []) {
      if (ch.kind === 'special' || ch.readonly || !ch.id) { ignored += countAll(ch); continue; }
      if (byId.has(ch.id)) throw new Error(`duplicate node id ${ch.id}`);
      kids.push(ch.id);
      walk(ch, node.id, depth + 1);
    }
    kids.forEach((id, i) => { byId.get(id).index = i; });
  };
  for (const rk of ROOTS) {
    const r = tree.roots?.[rk];
    if (!r) throw new Error(`tree is missing root ${rk}`);
    walk({ ...r, id: rk, kind: 'folder' }, null, 0);
  }
  return { byId, ignored };
}

function countAll(n) {
  let c = 1;
  for (const ch of n.children || []) c += countAll(ch);
  return c;
}

/** Iterate descendant ids (excluding the node itself), pre-order. */
export function* descendants(idx, id) {
  const rec = idx.byId.get(id);
  if (!rec) return;
  for (const ch of rec.children) {
    yield ch;
    yield* descendants(idx, ch);
  }
}

export function pathOf(idx, id, rootTitle) {
  const parts = [];
  let cur = idx.byId.get(id);
  while (cur && cur.parentId) {
    cur = idx.byId.get(cur.parentId);
    if (!cur) break;
    parts.unshift(cur.parentId ? cur.title : rootTitle(cur.id));
  }
  return parts.join(' / ');
}

// ---------------------------------------------------------------------------
// Simulator: nodes keyed by *sync key* (not side id).

export class SimTree {
  constructor() {
    this.nodes = new Map(); // key -> { key, kind, title, url, parent, children: [keys] }
  }

  static fromIndex(idx, keyOf) {
    const t = new SimTree();
    for (const [id, rec] of idx.byId) {
      const key = keyOf(id);
      t.nodes.set(key, { key, kind: rec.kind, title: rec.title, url: rec.url, parent: null, children: [] });
    }
    for (const [id, rec] of idx.byId) {
      const n = t.nodes.get(keyOf(id));
      n.parent = rec.parentId ? keyOf(rec.parentId) : null;
      n.children = rec.children.map(keyOf);
    }
    return t;
  }

  has(key) { return this.nodes.has(key); }
  get(key) { return this.nodes.get(key); }

  isAncestor(anc, key) {
    let cur = this.nodes.get(key);
    while (cur && cur.parent) {
      if (cur.parent === anc) return true;
      cur = this.nodes.get(cur.parent);
    }
    return false;
  }

  _insert(parentKey, key, after) {
    const p = this.nodes.get(parentKey);
    if (!p || p.kind !== 'folder') throw new SimError(`parent ${parentKey} missing`);
    if (after === 'END' || after === undefined) p.children.push(key);
    else if (after === null) p.children.unshift(key);
    else {
      const i = p.children.indexOf(after);
      if (i < 0) throw new SimError(`anchor ${after} not in ${parentKey}`);
      p.children.splice(i + 1, 0, key);
    }
    this.nodes.get(key).parent = parentKey;
  }

  _detach(key) {
    const n = this.nodes.get(key);
    const p = this.nodes.get(n.parent);
    if (p) p.children = p.children.filter((k) => k !== key);
    n.parent = null;
  }

  apply(op) {
    switch (op.op) {
      case 'create': {
        if (this.nodes.has(op.key)) throw new SimError(`key ${op.key} exists`);
        this.nodes.set(op.key, { key: op.key, kind: op.kind, title: op.title, url: op.kind === 'bookmark' ? op.url : null, parent: null, children: [] });
        this._insert(op.parent, op.key, op.after);
        break;
      }
      case 'update': {
        const n = this.nodes.get(op.key);
        if (!n) throw new SimError(`update: ${op.key} missing`);
        if (op.title !== undefined) n.title = op.title;
        if (op.url !== undefined) n.url = op.url;
        break;
      }
      case 'move': {
        const n = this.nodes.get(op.key);
        if (!n) throw new SimError(`move: ${op.key} missing`);
        if (op.key === op.parent || this.isAncestor(op.key, op.parent)) throw new SimError('move into own subtree');
        this._detach(op.key);
        this._insert(op.parent, op.key, op.after);
        break;
      }
      case 'remove': {
        const n = this.nodes.get(op.key);
        if (!n) throw new SimError(`remove: ${op.key} missing`);
        const stack = [op.key];
        this._detach(op.key);
        while (stack.length) {
          const k = stack.pop();
          const x = this.nodes.get(k);
          stack.push(...x.children);
          this.nodes.delete(k);
        }
        break;
      }
      default:
        throw new SimError(`unknown op ${op.op}`);
    }
  }

  subtreeKeys(key) {
    const out = [];
    const stack = [key];
    while (stack.length) {
      const k = stack.pop();
      const n = this.nodes.get(k);
      if (!n) continue;
      out.push(k);
      stack.push(...n.children);
    }
    return out;
  }
}

export class SimError extends Error {}
