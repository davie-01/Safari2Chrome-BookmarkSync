// Random edit on a random online endpoint of a multi world (see multi.test.js).
export async function randomEdit(w, rnd, tag) {
  const online = Object.keys(w.eps).filter((k) => w.online[k]);
  const who = online[Math.floor(rnd() * online.length)];
  const act = Math.floor(rnd() * 6);
  if (who === 'safari') {
    const s = w.safari;
    const all = [];
    const walk = (n) => { for (const c of n.children || []) { all.push(c); walk(c); } };
    for (const r of Object.values(s.roots)) walk(r);
    const folders = [...Object.values(s.roots), ...all.filter((n) => n.kind === 'folder')];
    const target = all[Math.floor(rnd() * all.length)];
    const folder = folders[Math.floor(rnd() * folders.length)];
    if (act <= 1 || !target) s.add(folder, `s${tag}`, rnd() < 0.3 ? undefined : `https://s${tag}.test/`);
    else if (act === 2) target.title += '*';
    else if (act === 3) { try { s.apply([{ op: 'move', id: target.id, parent: folder.id, after: rnd() < 0.5 ? null : 'END' }]); } catch { /* cycle */ } }
    else if (act === 4 && target.kind === 'bookmark') target.url = `https://edit${tag}.test/`;
    else s.apply([{ op: 'remove', id: target.id }]);
    return;
  }
  const f = w.browsers[who];
  const ids = [...f.nodes.keys()].filter((id) => !['0', '1', '2', '3'].includes(id));
  const folders = ['1', '2', ...ids.filter((id) => f.nodes.get(id).url === undefined)];
  const target = ids[Math.floor(rnd() * ids.length)];
  const folder = folders[Math.floor(rnd() * folders.length)];
  if (act <= 1 || !target) f.add(folder, `${who[0]}${tag}`, rnd() < 0.3 ? undefined : `https://${who[0]}${tag}.test/`);
  else if (act === 2) await f.update(target, { title: f.nodes.get(target).title + '+' });
  else if (act === 3) { try { await f.move(target, { parentId: folder, index: rnd() < 0.5 ? 0 : undefined }); } catch { /* cycle */ } }
  else if (act === 4 && f.nodes.get(target).url !== undefined) await f.update(target, { url: `https://${who[0]}edit${tag}.test/` });
  else await f.removeTree(target);
}
