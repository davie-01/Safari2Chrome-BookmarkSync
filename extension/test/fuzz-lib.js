export async function randomEdit(e, rnd, tag) {
  const side = rnd() < 0.5 ? 's' : 'c';
  const act = Math.floor(rnd() * 6);
  if (side === 's') {
    const all = [];
    const walk = (n) => { for (const c of n.children || []) { all.push(c); walk(c); } };
    for (const r of Object.values(e.safari.roots)) walk(r);
    const folders = [...Object.values(e.safari.roots), ...all.filter((n) => n.kind === 'folder')];
    const target = all[Math.floor(rnd() * all.length)];
    const folder = folders[Math.floor(rnd() * folders.length)];
    if (act <= 1 || !target) e.safari.add(folder, `s${tag}`, rnd() < 0.3 ? undefined : `https://s${tag}.test/`);
    else if (act === 2) target.title += '*';
    else if (act === 3) {
      const after = rnd() < 0.5 ? null : 'END';
      try { e.safari.apply([{ op: 'move', id: target.id, parent: folder.id, after }]); } catch { /* cycle */ }
    } else if (act === 4 && target.kind === 'bookmark') target.url = `https://edit${tag}.test/`;
    else e.safari.apply([{ op: 'remove', id: target.id }]);
  } else {
    const ids = [...e.chrome.nodes.keys()].filter((id) => !['0', '1', '2', '3'].includes(id));
    const folders = ['1', '2', ...ids.filter((id) => e.chrome.nodes.get(id).url === undefined)];
    const target = ids[Math.floor(rnd() * ids.length)];
    const folder = folders[Math.floor(rnd() * folders.length)];
    if (act <= 1 || !target) e.chrome.add(folder, `c${tag}`, rnd() < 0.3 ? undefined : `https://c${tag}.test/`);
    else if (act === 2) await e.chrome.update(target, { title: e.chrome.nodes.get(target).title + '+' });
    else if (act === 3) { try { await e.chrome.move(target, { parentId: folder, index: rnd() < 0.5 ? 0 : undefined }); } catch { /* cycle */ } }
    else if (act === 4 && e.chrome.nodes.get(target).url !== undefined) await e.chrome.update(target, { url: `https://cedit${tag}.test/` });
    else await e.chrome.removeTree(target);
  }
}

