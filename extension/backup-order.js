// Restore sibling order from a Netscape bookmark export (Chrome "导出书签" HTML).
// Only reorders children inside folders that exist in both; never moves items between
// folders, never creates or deletes anything.

const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", apos: "'" };
const unescape = (s) => s.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e) => {
  if (e[0] === '#') return String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
  return ENT[e.toLowerCase()] ?? m;
});

/** @returns {{ bar: Folder|null, other: Folder|null }}  Folder = {title, children:[Folder|{title,url}]} */
export function parseBookmarkHtml(html) {
  const tok = /<DT><H3([^>]*)>([\s\S]*?)<\/H3>|<DT><A\s[^>]*?HREF="([^"]*)"[^>]*>([\s\S]*?)<\/A>|<DL>|<\/DL>/gi;
  const root = { title: '', children: [] };
  const stack = [root];
  let pending = null;
  let m;
  while ((m = tok.exec(html))) {
    if (m[2] !== undefined) {
      pending = { title: unescape(m[2]), children: [], toolbar: /PERSONAL_TOOLBAR_FOLDER\s*=\s*"true"/i.test(m[1]) };
      stack[stack.length - 1].children.push(pending);
    } else if (m[3] !== undefined) {
      stack[stack.length - 1].children.push({ title: unescape(m[4]), url: unescape(m[3]) });
    } else if (m[0].toUpperCase() === '<DL>') {
      if (pending) { stack.push(pending); pending = null; }
    } else if (stack.length > 1) {
      stack.pop();
    }
  }
  // Chrome export: <DL> [书签栏 (toolbar)] [其他书签] [移动设备书签] or loose items for "other"
  const tops = root.children.length === 1 && !root.children[0].url && !root.children[0].toolbar && root.children[0].children.some((c) => c.toolbar)
    ? root.children[0].children : root.children;
  const bar = tops.find((c) => c.toolbar) || null;
  const rest = tops.filter((c) => c !== bar);
  const otherFolder = rest.find((c) => !c.url && /^(其他书签|Other bookmarks|其他書籤)$/i.test(c.title));
  const other = otherFolder || (rest.length ? { title: 'other', children: rest.filter((c) => !/^(移动设备书签|Mobile bookmarks)$/i.test(c.title)) } : null);
  return { bar, other };
}

function canon(u) { try { return new URL(u).href; } catch { return u; } }

/** Pair backup children with current Chrome children (duplicates consumed in order). */
function pairChildren(backupKids, chromeKids) {
  const used = new Set();
  const out = [];
  const passes = [
    (b, c) => (b.url === undefined) === (c.url === undefined) && b.title === c.title && (b.url === undefined || canon(b.url) === canon(c.url)),
    (b, c) => b.url !== undefined && c.url !== undefined && canon(b.url) === canon(c.url),
    (b, c) => b.url === undefined && c.url === undefined && b.title === c.title,
  ];
  const match = new Array(backupKids.length).fill(null);
  for (const eq of passes) {
    backupKids.forEach((b, i) => {
      if (match[i]) return;
      const c = chromeKids.find((x) => !used.has(x.id) && eq(b, x));
      if (c) { used.add(c.id); match[i] = c; }
    });
  }
  backupKids.forEach((b, i) => { if (match[i]) out.push([b, match[i]]); });
  return out;
}

/**
 * Reorder Chrome folders to follow the backup.
 * @param api promise-based chrome.bookmarks
 * @param rootIds { 'root:bar': id, 'root:other': id }
 */
export async function restoreChromeOrder(api, rootIds, backup, { dryRun = false } = {}) {
  const stats = { folders: 0, reordered: 0, moves: 0, matched: 0, unmatched: 0 };
  const walk = async (bFolder, chromeId) => {
    const kids = await api.getChildren(chromeId);
    const pairs = pairChildren(bFolder.children, kids);
    stats.folders++;
    stats.matched += pairs.length;
    stats.unmatched += kids.length - pairs.length;
    const matchedIds = new Set(pairs.map(([, c]) => c.id));
    const desired = [...pairs.map(([, c]) => c.id), ...kids.filter((k) => !matchedIds.has(k.id)).map((k) => k.id)];
    const current = kids.map((k) => k.id);
    if (desired.some((id, i) => id !== current[i])) {
      stats.reordered++;
      const cur = [...current];
      for (let i = 0; i < desired.length; i++) {
        if (cur[i] === desired[i]) continue;
        stats.moves++;
        if (!dryRun) await api.move(desired[i], { parentId: chromeId, index: i });
        const from = cur.indexOf(desired[i]);
        cur.splice(from, 1);
        cur.splice(i, 0, desired[i]);
      }
    }
    for (const [b, c] of pairs) if (b.url === undefined && c.url === undefined) await walk(b, c.id);
  };
  if (backup.bar && rootIds['root:bar']) await walk(backup.bar, rootIds['root:bar']);
  if (backup.other && rootIds['root:other']) await walk(backup.other, rootIds['root:other']);
  return stats;
}
