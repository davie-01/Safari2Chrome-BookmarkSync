// Test doubles: a fake chrome.bookmarks with Chromium's index semantics, and a JS
// reference of the Safari agent's op semantics (the Swift agent must match it).

export class FakeChrome {
  constructor({ account = false } = {}) {
    this.nextId = 100;
    this.nodes = new Map();
    const root = { id: '0', title: '', children: [] };
    this.nodes.set('0', root);
    const mk = (id, title, folderType, syncing) => {
      const n = { id, parentId: '0', title, children: [], folderType, syncing };
      this.nodes.set(id, n);
      root.children.push(id);
    };
    mk('1', 'Bookmarks bar', 'bookmarks-bar', false);
    mk('2', 'Other bookmarks', 'other', false);
    mk('3', 'Mobile bookmarks', 'mobile', false);
    if (account) {
      mk('4', 'Bookmarks bar', 'bookmarks-bar', true);
      mk('5', 'Other bookmarks', 'other', true);
    }
    this.calls = [];
  }

  _out(n, deep = true) {
    const o = { id: n.id, parentId: n.parentId, title: n.title };
    if (n.url !== undefined) o.url = n.url;
    else if (deep) o.children = n.children.map((c) => this._out(this.nodes.get(c)));
    if (n.folderType) o.folderType = n.folderType;
    if (n.syncing !== undefined) o.syncing = n.syncing;
    const p = this.nodes.get(n.parentId);
    if (p) o.index = p.children.indexOf(n.id);
    return o;
  }

  async getTree() { return [this._out(this.nodes.get('0'))]; }
  async getChildren(id) { return this.nodes.get(id).children.map((c) => this._out(this.nodes.get(c), false)); }
  async get(id) { const n = this.nodes.get(id); if (!n) throw new Error("Can't find bookmark for id."); return [this._out(n, false)]; }

  async create({ parentId, index, title, url }) {
    this.calls.push(['create', title]);
    const p = this.nodes.get(parentId);
    if (!p || p.url !== undefined) throw new Error("Can't find parent bookmark for id.");
    const id = String(this.nextId++);
    const n = { id, parentId, title: title ?? '', children: [] };
    if (url !== undefined) { n.url = canonical(url); delete n.children; }
    this.nodes.set(id, n);
    if (index === undefined) p.children.push(id);
    else { if (index > p.children.length) throw new Error('Index out of bounds.'); p.children.splice(index, 0, id); }
    return this._out(n, false);
  }

  async update(id, { title, url }) {
    this.calls.push(['update', id]);
    const n = this.nodes.get(id);
    if (title !== undefined) n.title = title;
    if (url !== undefined) n.url = canonical(url);
    return this._out(n, false);
  }

  // Mirrors BookmarkModel::Move: index is interpreted before removal.
  async move(id, { parentId, index }) {
    this.calls.push(['move', id]);
    const n = this.nodes.get(id);
    const oldP = this.nodes.get(n.parentId);
    const newP = this.nodes.get(parentId ?? n.parentId);
    for (let cur = newP; cur; cur = this.nodes.get(cur.parentId)) {
      if (cur.id === id) throw new Error("Can't move a folder into its own descendant.");
    }
    const oldIndex = oldP.children.indexOf(id);
    if (index === undefined) index = newP.children.length;
    if (oldP === newP && (index === oldIndex || index === oldIndex + 1)) return this._out(n, false);
    oldP.children.splice(oldIndex, 1);
    if (oldP === newP && index > oldIndex) index--;
    newP.children.splice(index, 0, id);
    n.parentId = newP.id;
    return this._out(n, false);
  }

  async remove(id) {
    this.calls.push(['remove', id]);
    const n = this.nodes.get(id);
    if (n.url === undefined && n.children.length) throw new Error("Can't remove non-empty folder (use recursive to force).");
    this._drop(id);
  }

  async removeTree(id) { this.calls.push(['removeTree', id]); this._drop(id); }

  _drop(id) {
    const n = this.nodes.get(id);
    const p = this.nodes.get(n.parentId);
    p.children = p.children.filter((c) => c !== id);
    const stack = [id];
    while (stack.length) {
      const k = stack.pop();
      const x = this.nodes.get(k);
      if (x.children) stack.push(...x.children);
      this.nodes.delete(k);
    }
  }

  // helpers for tests
  add(parentId, title, url) {
    const id = String(this.nextId++);
    const n = { id, parentId, title, children: [] };
    if (url !== undefined) { n.url = canonical(url); delete n.children; }
    this.nodes.set(id, n);
    this.nodes.get(parentId).children.push(id);
    return id;
  }
}

function canonical(u) {
  try { return new URL(u).href; } catch { return u; }
}

// ---------------------------------------------------------------------------
// Safari reference store: normalized tree + UUIDs, same op semantics as the Swift agent.

export class FakeSafari {
  constructor() {
    this.n = 0;
    this.roots = {
      'root:bar': { id: 'root:bar', kind: 'folder', title: 'BookmarksBar', children: [] },
      'root:other': { id: 'root:other', kind: 'folder', title: 'BookmarksMenu', children: [] },
    };
  }

  uuid() { return `UUID-${String(++this.n).padStart(4, '0')}`; }

  add(parent, title, url) {
    const p = typeof parent === 'string' ? this.find(parent) : parent;
    const node = url === undefined
      ? { id: this.uuid(), kind: 'folder', title, children: [] }
      : { id: this.uuid(), kind: 'bookmark', title, url };
    p.children.push(node);
    return node.id;
  }

  find(id) {
    let hit = null;
    const walk = (n, parent) => {
      if (n.id === id) hit = { n, parent };
      for (const c of n.children || []) walk(c, n);
    };
    for (const r of Object.values(this.roots)) walk(r, null);
    return hit ? hit.n : null;
  }

  findWithParent(id) {
    let hit = null;
    const walk = (n, parent) => {
      if (n.id === id) hit = { n, parent };
      for (const c of n.children || []) walk(c, n);
    };
    for (const r of Object.values(this.roots)) walk(r, null);
    return hit;
  }

  tree() { return { roots: structuredClone(this.roots) }; }

  /** All-or-nothing, like the agent. Throws on precondition failure without changing anything. */
  apply(ops) {
    const backup = structuredClone(this.roots);
    try {
      for (const op of ops) this._one(op);
    } catch (e) {
      this.roots = backup;
      throw e;
    }
  }

  _insert(parent, node, after) {
    if (!parent || parent.kind !== 'folder') throw new Error('parent missing');
    if (after === 'END' || after === undefined) parent.children.push(node);
    else if (after === null) parent.children.unshift(node);
    else {
      const i = parent.children.findIndex((c) => c.id === after);
      if (i < 0) throw new Error('anchor missing');
      parent.children.splice(i + 1, 0, node);
    }
  }

  _one(op) {
    switch (op.op) {
      case 'create': {
        if (this.find(op.id)) throw new Error('duplicate uuid');
        const node = op.kind === 'folder'
          ? { id: op.id, kind: 'folder', title: op.title, children: [] }
          : { id: op.id, kind: 'bookmark', title: op.title, url: op.url };
        this._insert(this.find(op.parent), node, op.after);
        break;
      }
      case 'update': {
        const n = this.find(op.id);
        if (!n) throw new Error('missing');
        if (op.expect) {
          if (op.expect.title !== undefined && n.title !== op.expect.title) throw new Error('precondition title');
          if (op.expect.url !== undefined && n.url !== op.expect.url) throw new Error('precondition url');
        }
        if (op.title !== undefined) n.title = op.title;
        if (op.url !== undefined) n.url = op.url;
        break;
      }
      case 'move': {
        const hit = this.findWithParent(op.id);
        if (!hit || !hit.parent) throw new Error('missing');
        const dest = this.find(op.parent);
        let p = dest;
        // cycle check
        const inSub = (root, id) => root.id === id || (root.children || []).some((c) => inSub(c, id));
        if (inSub(hit.n, op.parent)) throw new Error('cycle');
        hit.parent.children = hit.parent.children.filter((c) => c.id !== op.id);
        this._insert(p, hit.n, op.after);
        break;
      }
      case 'remove': {
        const hit = this.findWithParent(op.id);
        if (!hit || !hit.parent) throw new Error('missing');
        if (op.expect) {
          if (op.expect.title !== undefined && hit.n.title !== op.expect.title) throw new Error('precondition title');
        }
        hit.parent.children = hit.parent.children.filter((c) => c.id !== op.id);
        break;
      }
      default: throw new Error('bad op');
    }
  }
}
