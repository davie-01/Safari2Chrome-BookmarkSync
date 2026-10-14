// Chrome side: normalize chrome.bookmarks.getTree() and execute plan ops through the
// supported bookmarks API. `api` is a promise-based object with the chrome.bookmarks
// surface (getTree, getChildren, get, create, move, update, remove, removeTree), so the
// executor can be tested with a fake.

const ROLE_BY_TYPE = { 'bookmarks-bar': 'root:bar', other: 'root:other', mobile: 'mobile', managed: 'managed' };
const ROLE_BY_ID = { 1: 'root:bar', 2: 'root:other', 3: 'mobile' };

/** Which top-level folders exist (for settings UI). */
export function listChromeStores(treeRoot) {
  const out = [];
  for (const n of treeRoot.children || []) {
    const role = n.folderType ? ROLE_BY_TYPE[n.folderType] : ROLE_BY_ID[n.id];
    out.push({ id: n.id, title: n.title, role: role || 'unknown', syncing: n.syncing === true });
  }
  return out;
}

/**
 * @param treeRoot result[0] of chrome.bookmarks.getTree()
 * @param store 'auto' | 'account' | 'local'
 * @returns {{ tree, rootIds: {'root:bar': id, 'root:other': id}, store }}
 */
export function normalizeChrome(treeRoot, store = 'auto') {
  const tops = (treeRoot.children || []).map((n) => ({
    n,
    role: n.folderType ? ROLE_BY_TYPE[n.folderType] : ROLE_BY_ID[n.id],
    syncing: n.syncing === true,
  }));
  const hasAccount = tops.some((t) => t.syncing && (t.role === 'root:bar' || t.role === 'root:other'));
  const want = store === 'auto' ? (hasAccount ? 'account' : 'local') : store;
  const pick = (role) => {
    const cands = tops.filter((t) => t.role === role);
    const match = cands.find((t) => (want === 'account' ? t.syncing : !t.syncing));
    return (match || cands[0])?.n;
  };
  const conv = (n) => {
    if (n.url !== undefined) {
      return { id: n.id, kind: 'bookmark', title: n.title ?? '', url: n.url, ...(n.unmodifiable ? { readonly: true } : {}) };
    }
    return {
      id: n.id, kind: 'folder', title: n.title ?? '',
      ...(n.unmodifiable ? { readonly: true } : {}),
      children: (n.children || []).map(conv),
    };
  };
  const roots = {};
  const rootIds = {};
  for (const role of ['root:bar', 'root:other']) {
    const n = pick(role);
    if (!n) throw new Error(`Chrome root ${role} not found`);
    rootIds[role] = n.id;
    roots[role] = { id: role, kind: 'folder', title: n.title, children: (n.children || []).map(conv) };
  }
  return { tree: { roots }, rootIds, store: want };
}

export class ExecError extends Error {
  constructor(message, op, index) {
    super(message);
    this.op = op;
    this.index = index;
  }
}

/**
 * Execute Chrome ops sequentially. Stops at the first failure (later ops may depend on it).
 * @returns {{ created: Record<string,string>, done: number, error?: {message, index, op} }}
 */
export async function executeChrome(ops, api, rootIds, { onProgress } = {}) {
  const created = {};
  const resolve = (ref) => {
    if (ref === null || ref === undefined || ref === 'END') return ref;
    if (typeof ref === 'string') return rootIds[ref] ?? ref;
    if (ref.key) {
      const id = created[ref.key];
      if (!id) throw new Error(`unresolved reference ${ref.key}`);
      return id;
    }
    throw new Error('bad reference');
  };
  const indexAfter = async (parentId, after) => {
    if (after === 'END' || after === undefined) return undefined;
    if (after === null) return 0;
    const anchor = resolve(after);
    const kids = await api.getChildren(parentId);
    const i = kids.findIndex((k) => k.id === anchor);
    if (i < 0) throw new Error('anchor not found in parent');
    return i + 1;
  };
  const getOne = async (id) => {
    const r = await api.get(id).catch(() => []);
    if (!r || !r.length) throw new Error('node not found');
    return r[0];
  };
  const checkExpect = (node, expect) => {
    if (!expect) return;
    if (expect.kind && (expect.kind === 'bookmark') !== (node.url !== undefined)) throw new Error('precondition: kind changed');
    if (expect.title !== undefined && node.title !== expect.title) throw new Error('precondition: title changed');
    if (expect.url !== undefined && node.url !== expect.url) throw new Error('precondition: url changed');
  };

  let done = 0;
  for (let i = 0; i < ops.length; i++) {
    const op = ops[i];
    try {
      switch (op.op) {
        case 'create': {
          const parentId = resolve(op.parent);
          const index = await indexAfter(parentId, op.after);
          const props = { parentId, title: op.title };
          if (index !== undefined) props.index = index;
          if (op.kind === 'bookmark') props.url = op.url;
          const node = await api.create(props);
          created[op.key] = node.id;
          break;
        }
        case 'update': {
          const id = resolve(op.id);
          checkExpect(await getOne(id), op.expect);
          const changes = {};
          if (op.title !== undefined) changes.title = op.title;
          if (op.url !== undefined) changes.url = op.url;
          await api.update(id, changes);
          break;
        }
        case 'move': {
          const id = resolve(op.id);
          const parentId = resolve(op.parent);
          const index = await indexAfter(parentId, op.after);
          const dest = { parentId };
          if (index !== undefined) dest.index = index;
          await api.move(id, dest);
          break;
        }
        case 'remove': {
          const id = resolve(op.id);
          const node = await getOne(id);
          checkExpect(node, op.expect);
          if (node.url === undefined) await api.removeTree(id);
          else await api.remove(id);
          break;
        }
        default:
          throw new Error(`unknown op ${op.op}`);
      }
      done++;
      onProgress?.(done, ops.length);
    } catch (e) {
      return { created, done, error: { message: e.message, index: i, op } };
    }
  }
  return { created, done };
}
