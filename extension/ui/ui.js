import { t, useLang, translateDom, locale, currentLang } from './i18n.js';
// Diff preview / selection UI for the multi-endpoint engine. Talks to a backend through
// `call(type, payload)` (chrome.runtime in the extension; the App provides the same
// surface in its web view). Every item is a decision on ONE endpoint relative to the
// unified version ("其他端"), or a cross-endpoint conflict (type 'multiConflict').

const $ = (s) => document.querySelector(s);
const TYPE_ICON = { create: '+', modify: '✎', delete: '−', conflict: '!', deleteConflict: '!', multiConflict: '!', order: '⇅' };
const TYPE_GROUP = { create: 'create', modify: 'modify', delete: 'delete', conflict: 'conflict', deleteConflict: 'conflict', multiConflict: 'conflict', order: 'order' };
// Filled in once the language is known (see the boot block at the bottom).
let FIELD = {};
let MODE = {};
let OTHERS = '其他端';
function buildLabels() {
  FIELD = { title: t('标题'), url: t('网址'), parent: t('位置') };
  MODE = { both: t('双向'), receive: t('只接收'), send: t('只发送') };
  OTHERS = t('其他端');
}

const ui = {
  status: null,
  scan: null,
  choices: {},
  filter: 'all',
  query: '',
};

/** Paths come from the engine as "书签栏 / 工作"; only the root segment is a UI label. */
function uiPath(p) {
  if (!p) return p;
  for (const zh of ['书签栏', '其他书签 / Safari 顶层']) {
    if (p === zh || p.startsWith(`${zh} /`)) return t(zh) + p.slice(zh.length);
  }
  return p;
}

function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'text') el.textContent = v;
    else if (k === 'value') el.value = v;
    else if (k === 'checked') el.checked = !!v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

const backend = globalThis.BookmarkSyncBackend || {
  async call(type, payload) { return chrome.runtime.sendMessage({ type, ...payload }); },
  onEvent(fn) { chrome.runtime.onMessage.addListener((m) => { if (m?.type === 'event') fn(m); }); },
};

async function call(type, payload = {}) {
  const res = await backend.call(type, payload);
  if (!res) throw new Error(t('后台没有响应'));
  if (!res.ok) throw Object.assign(new Error(res.error?.message || t('失败')), { code: res.error?.code });
  return res.result;
}

// ---- status / setup ---------------------------------------------------------

async function loadStatus() {
  try {
    ui.status = await call('status');
  } catch (e) {
    ui.status = { agentError: { code: 'error', message: e.message } };
  }
  renderStatus();
}

function chip(text, cls, title) {
  return h('span', { class: `chip ${cls}`, title }, text);
}

function renderStatus() {
  const st = ui.status;
  const chips = $('#chips');
  chips.replaceChildren();
  const setup = $('#setup');
  if (st.agentError || !st.agent) {
    chips.append(chip(t('后台服务未连接'), 'bad', st.agentError?.message));
    setup.hidden = false;
    setup.replaceChildren(
      h('h2', {}, t('需要先安装本机组件')),
      h('p', { class: 'muted' }, t('连接失败：{msg}', { msg: st.agentError?.message || t('未知错误') })),
      h('ol', {},
        h('li', {}, t('安装并打开 BookmarkSync.app（源码编译：'), h('code', {}, './scripts/build-app.sh'), '）'),
        h('li', {}, t('打开 系统设置 → 隐私与安全性 → 完全磁盘访问权限，加入并勾选 BookmarkSync.app')),
        h('li', {}, t('刷新本页')),
      ),
    );
    $('#btn-scan').disabled = true;
    return;
  }
  const a = st.agent;
  const settings = st.settings || {};
  chips.append(chip(t('后台服务 {v}', { v: a.version }), a.engine === false ? 'bad' : 'ok', a.engine === false ? t('同步引擎加载失败，见日志') : ''));
  for (const ep of a.endpoints || []) {
    const pref = settings.endpoints?.[ep.id] || {};
    const off = pref.enabled === false;
    const me = ep.id === st.endpointId ? t('（本浏览器）') : '';
    const mode = pref.mode && pref.mode !== 'both' ? ` · ${MODE[pref.mode]}` : '';
    chips.append(chip(`${ep.name}${me}${mode}${off ? t(' · 已停用') : ''}`, off ? 'warn' : ep.online ? 'ok' : 'bad', ep.online ? t('在线') : t('不可用')));
  }
  if (a.safariAccess !== 'ok') chips.append(chip(a.safariAccess === 'noFullDiskAccess' ? t('缺少完全磁盘访问权限') : t('Safari 书签：{s}', { s: a.safariAccess }), 'bad'));
  const live = settings.safariWhileRunning !== false;
  if (a.safariRunning && !live) chips.append(chip(t('Safari 运行中（Safari 端写入会等它退出）'), 'warn'));
  if (settings.autoSync) chips.append(chip(t('常驻自动同步'), 'ok'));
  const p = st.pending;
  if (p?.heldDeletes) chips.append(chip(t('{n} 项删除待确认', { n: p.heldDeletes }), 'warn'));
  if (p?.conflicts) chips.append(chip(t('{n} 项冲突待处理', { n: p.conflicts }), 'warn'));
  if (p?.heldOrders) chips.append(chip(t('{n} 个文件夹顺序待确认', { n: p.heldOrders }), 'warn'));

  if (a.safariAccess === 'noFullDiskAccess') {
    setup.hidden = false;
    setup.replaceChildren(
      h('h2', {}, t('需要「完全磁盘访问权限」')),
      h('p', {}, t('Safari 的书签文件受系统保护。请在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中加入并勾选 BookmarkSync.app，然后重新打开 BookmarkSync。')),
    );
  } else setup.hidden = true;
  $('#btn-scan').disabled = false;
  const names = (a.endpoints || []).filter((e) => e.online).map((e) => e.name);
  $('#sub').textContent = names.length ? names.join(' ↔ ') : t('Safari ↔ Chromium 浏览器');
}

// ---- scan / list ------------------------------------------------------------------

async function doScan() {
  if (!$('#history-view').hidden) closeHistory();
  const btn = $('#btn-scan');
  btn.disabled = true;
  btn.textContent = t('扫描中…');
  try {
    ui.scan = await call('scan');
    ui.choices = {};
    $('#result').hidden = true;
    renderScan();
  } catch (e) {
    showError(t('扫描失败'), e);
  } finally {
    btn.disabled = false;
    btn.textContent = t('重新扫描');
  }
}

function effective(it) { return ui.choices[it.id] ?? it.default; }

const nameC = (it) => it.epName;
const nameS = (it) => it.againstName || OTHERS;

function choiceLabel(it, c) {
  if (c === 'ignore') return t('忽略');
  switch (it.type) {
    case 'modify': return c === 'apply' ? t('同步到{o}', { o: OTHERS }) : t('还原 {ep}', { ep: nameC(it) });
    case 'conflict': return c === 'useS' ? t('用 {ep} 的', { ep: nameS(it) }) : t('用 {ep} 的', { ep: nameC(it) });
    case 'create': return c === 'apply' ? t('同步到{o}', { o: OTHERS }) : t('从 {ep} 删除', { ep: nameC(it) });
    case 'delete':
    case 'deleteConflict':
      if (it.deletedOn === 'c') return c === 'apply' ? t('{o}也删除', { o: OTHERS }) : t('恢复到 {ep}', { ep: nameC(it) });
      return c === 'apply' ? t('{ep} 也删除', { ep: nameC(it) }) : t('恢复到{o}', { o: OTHERS });
    case 'order': return c === 'useS' ? t('用{o}的顺序', { o: OTHERS }) : t('用 {ep} 的顺序', { ep: nameC(it) });
    case 'multiConflict': {
      const ep = it.endpoints.find((e) => `use:${e.ep}` === c);
      return ep ? t('用 {ep} 的', { ep: ep.name }) : c;
    }
    default: return c;
  }
}

function isDestructive(it, c) {
  if (it.type === 'create') return c === 'remove';
  if (it.type === 'delete' || it.type === 'deleteConflict') return c === 'apply';
  if (it.type === 'multiConflict') return !!it.endpoints.find((e) => `use:${e.ep}` === c)?.deleted;
  return false;
}

function display(it) {
  if (it.type === 'multiConflict') return it.s || it.endpoints[0];
  return it.c || it.s;
}

function matches(it) {
  if (ui.filter !== 'all' && TYPE_GROUP[it.type] !== ui.filter) return false;
  if (!ui.query) return true;
  const q = ui.query.toLowerCase();
  const infos = it.type === 'multiConflict' ? [it.s, ...it.endpoints] : [it.s, it.c];
  return infos.some((x) => x && [x.title, x.url, x.path].some((v) => v && v.toLowerCase().includes(q)));
}

function renderScan() {
  const sc = ui.scan;
  const items = sc.items;
  const eps = sc.endpoints || [];
  $('#scan-meta-row').hidden = false;
  $('#scan-meta').textContent = `${eps.map((e) => e.name).join(' · ')}` + (sc.offline?.length ? t(' · 不可用：{list}', { list: sc.offline.map((o) => o.name).join(t('、')) }) : '');

  const w = $('#warnings');
  w.replaceChildren();
  if (sc.firstSync) {
    w.append(h('div', { class: 'card warn-banner' },
      h('b', {}, t('首次同步')), t('：新加入的浏览器里，和其他端相同的书签（同一文件夹下标题与网址一致）已自动配对；其余会合并过来，不会删除任何东西。')));
  }
  for (const warn of sc.warnings || []) {
    if (warn.code === 'massMissing') {
      w.append(h('div', { class: 'card warn-banner bad' },
        h('b', {}, t('注意：')), t('{ep} 中有 {gone}/{total} 个已同步项目不见了。', { ep: warn.epName, gone: warn.gone, total: warn.total }),
        t('如果不是你主动删除的（例如 iCloud 正在重建书签），请不要勾选删除；删除默认都不会执行。')));
    }
  }

  const counts = { all: items.length, create: 0, modify: 0, delete: 0, conflict: 0, order: 0 };
  for (const it of items) counts[TYPE_GROUP[it.type]]++;
  for (const el of document.querySelectorAll('[data-count]')) el.textContent = counts[el.dataset.count] || '';
  const writes = Object.entries(sc.preview || {}).filter(([k]) => k !== 'hub').reduce((a, [, v]) => a + (v.total || 0), 0);
  $('#filters').hidden = items.length === 0;
  $('#bar').hidden = items.length === 0 && writes === 0;
  const empty = $('#empty');
  empty.hidden = items.length !== 0;
  if (!items.length) empty.textContent = writes ? t('没有需要你决定的项目；还有 {n} 个已确定的改动要写入各端，点「执行同步」即可。', { n: writes }) : t('所有浏览器已经一致，没有需要同步的内容。');

  renderList();
  renderPlan(sc.preview);
}

function renderList() {
  const list = $('#list');
  list.replaceChildren();
  const groups = new Map();
  for (const it of ui.scan.items) {
    if (!matches(it)) continue;
    const inf = display(it);
    const path = uiPath(it.type === 'order' ? [inf?.path, inf?.title].filter(Boolean).join(' / ') : inf?.path || t('(根)'));
    if (!groups.has(path)) groups.set(path, { path, items: [] });
    groups.get(path).items.push(it);
  }
  for (const g of groups.values()) {
    list.append(h('section', { class: 'group' },
      h('header', {},
        h('span', { class: 'path', title: g.path }, g.path),
        h('span', { class: 'muted small' }, t('{n} 项', { n: g.items.length })),
        h('button', { type: 'button', class: 'ghost small', onclick: () => bulk(g.items, 'default') }, t('默认')),
        h('button', { type: 'button', class: 'ghost small', onclick: () => bulk(g.items, 'ignore') }, t('忽略本组')),
      ),
      g.items.map(renderItem)));
  }
  if (!groups.size && ui.scan.items.length) list.append(h('div', { class: 'card empty' }, t('没有符合筛选条件的项目')));
}

function tagFor(it) {
  const c = nameC(it);
  switch (it.type) {
    case 'create': return t('{ep} 新增', { ep: c });
    case 'modify': return t('{ep} 修改', { ep: c });
    case 'delete': return it.deletedOn === 'c' ? t('{ep} 删除了', { ep: c }) : t('{o}已删除', { o: OTHERS });
    case 'deleteConflict': return it.deletedOn === 'c' ? t('{ep} 删除了 · {other} 有改动', { ep: c, other: nameS(it) }) : t('{other} 删除了 · {ep} 有改动', { other: nameS(it), ep: c });
    case 'conflict': return it.firstSync ? t('首次同步：{ep} 与{o}不一致', { ep: c, o: OTHERS }) : t('{other} 和 {ep} 都改了', { other: nameS(it), ep: c });
    case 'order': {
      const who = it.changedBy === 'c' ? t('{ep} 调整了顺序', { ep: c }) : it.changedBy === 'both' ? t('{ep} 和{o}都调整了顺序', { ep: c, o: OTHERS }) : t('{ep} 与{o}顺序不同', { ep: c, o: OTHERS });
      return who + (it.suspicious ? t(' · 大范围重排，需确认') : '');
    }
    case 'multiConflict': return t('{list} 改得不一样', { list: it.endpoints.map((e) => e.name).join(t('、')) });
    default: return it.type;
  }
}

function renderItem(it) {
  const inf = display(it);
  const choice = effective(it);
  const row = h('div', { class: `item t-${it.type}${choice === 'ignore' ? ' ignored' : ''}`, 'data-id': it.id });
  const main = h('div', { class: 'main' },
    h('div', { class: 'title-line' },
      h('span', { class: 'ttl' }, inf?.title || t('(无标题)')),
      it.kind === 'folder' && it.type !== 'order' && h('span', { class: 'muted small' }, t('文件夹')),
      it.type === 'order' ? h('span', { class: 'muted small' }, t('文件夹内 {n} 项的排列顺序', { n: it.count }))
        : it.count > 1 && h('span', { class: 'muted small' }, t('含 {n} 个子项', { n: it.count - 1 })),
      h('span', { class: 'tag' }, tagFor(it))),
    it.kind === 'bookmark' && inf?.url && h('div', { class: 'url' }, inf.url),
    renderChanges(it),
    renderSubtree(it));
  const choices = h('div', { class: 'choices', role: 'radiogroup' },
    it.choices.map((c) => h('button', {
      type: 'button',
      class: `${c === choice ? 'on' : ''} ${isDestructive(it, c) ? 'destructive' : ''}`,
      'aria-checked': String(c === choice),
      role: 'radio',
      onclick: () => { ui.choices[it.id] = c; rerenderItem(it); updatePreview(); },
    }, choiceLabel(it, c))));
  row.append(h('div', { class: 'icon', 'aria-hidden': 'true' }, TYPE_ICON[it.type] || '?'), main, choices);
  return row;
}

function rerenderItem(it) {
  const old = document.querySelector(`.item[data-id="${CSS.escape(it.id)}"]`);
  if (old) old.replaceWith(renderItem(it));
}

function fieldVal(x, f) {
  if (!x) return '';
  if (f === 'parent') return uiPath(x.path) || t('(根)');
  return x[f] ?? '';
}

function renderOrder(it) {
  const cell = (side, label) => h('div', { class: 'order-col' },
    h('span', { class: 'tag' }, label),
    h('ol', {}, (it[side]?.order || []).map((t, i) => {
      const moved = it[side === 's' ? 'c' : 's']?.order?.[i] !== t;
      return h('li', { class: moved ? 'moved' : '' }, t || t('(无标题)'));
    })));
  return h('details', { class: 'subtree', open: it.count <= 15 ? true : null },
    h('summary', {}, t('对比顺序（标色为位置不同）')),
    h('div', { class: 'order-cmp' }, cell('s', OTHERS), cell('c', nameC(it))));
}

function renderChanges(it) {
  if (it.type === 'order') return renderOrder(it);
  if (it.type === 'modify') {
    return h('ul', { class: 'changes' }, it.fields.map((f) => h('li', {},
      h('span', { class: 'k' }, FIELD[f]),
      h('del', {}, fieldVal(it.s, f)), '→', h('ins', {}, fieldVal(it.c, f)))));
  }
  if (it.type === 'conflict') {
    return h('ul', { class: 'changes' }, it.fields.map((f) => h('li', {},
      h('span', { class: 'k' }, FIELD[f]),
      h('span', { class: 'vs' },
        h('span', { class: 'tag' }, nameS(it)), h('span', {}, fieldVal(it.s, f)),
        h('span', { class: 'tag' }, nameC(it)), h('span', {}, fieldVal(it.c, f))))));
  }
  if (it.type === 'multiConflict') {
    return h('ul', { class: 'changes' },
      h('li', {}, h('span', { class: 'k' }, t('原来')), h('span', {}, `${it.b?.title ?? it.s?.title ?? ''}`)),
      it.endpoints.map((e) => h('li', {},
        h('span', { class: 'tag' }, e.name),
        e.deleted ? h('del', {}, t('已删除'))
          : h('span', {}, Object.entries(e.fields || {}).map(([f, v]) => t('{field}：{value}', { field: FIELD[f], value: f === 'parent' ? (uiPath(e.path) || t('(根)')) : v })).join(t('；'))))));
  }
  return null;
}

function renderSubtree(it) {
  if (!it.subtree || !it.subtree.length) return null;
  return h('details', { class: 'subtree' },
    h('summary', {}, t('查看文件夹内容（{n}）', { n: it.count - 1 })),
    h('ul', {}, it.subtree.map((l) => l.more
      ? h('li', { class: 'muted' }, t('… 仅显示前 200 项'))
      : h('li', { style: `padding-left:${(l.depth - 1) * 16}px`, title: l.url || '' },
        l.kind === 'folder' ? '📁 ' : '', l.title || t('(无标题)'), l.url ? h('span', { class: 'muted' }, `  ${l.url}`) : null))));
}

function bulk(items, mode) {
  for (const it of items) {
    if (mode === 'default') delete ui.choices[it.id];
    else if (mode === 'ignore') ui.choices[it.id] = 'ignore';
  }
  renderList();
  updatePreview();
}

// ---- plan preview / run ---------------------------------------------------------------

let previewTimer = null;
function updatePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(async () => {
    if (!ui.scan) return;
    try {
      const p = await call('preview', { scanId: ui.scan.scanId, choices: ui.choices });
      // the decision list can change with choices (e.g. an ignored new folder on one browser)
      const ids = (x) => x.map((i) => i.id).join('\n');
      if (ids(p.items) !== ids(ui.scan.items)) { ui.scan = { ...ui.scan, items: p.items }; renderList(); }
      renderPlan(p.preview);
    } catch (e) {
      $('#plan').textContent = e.message;
    }
  }, 150);
}

function sideSummary(name, s) {
  const parts = [];
  if (s.create) parts.push(t('新增 {n}', { n: s.create }));
  if (s.update) parts.push(t('修改 {n}', { n: s.update }));
  if (s.move) parts.push(t('移动 {n}', { n: s.move }));
  if (s.remove) parts.push(h('span', { class: 'rm' }, t('删除 {n}', { n: s.remove })));
  if (s.reorderFolders) parts.push(t('排序 {n} 个文件夹', { n: s.reorderFolders }));
  return h('span', { class: 'side' }, h('b', {}, t('写入 {ep}：', { ep: name })), parts.length ? parts.flatMap((x, i) => (i ? [' · ', x] : [x])) : h('span', { class: 'muted' }, t('无')));
}

function renderPlan(preview) {
  ui.preview = preview || {};
  const plan = $('#plan');
  plan.replaceChildren();
  let total = 0;
  for (const ep of ui.scan?.endpoints || []) {
    const s = ui.preview[ep.id];
    if (!s) continue;
    total += s.total;
    plan.append(sideSummary(ep.name, s));
  }
  $('#btn-run').disabled = total === 0 && !(ui.preview.hub?.total);
}

async function doRun() {
  const p = ui.preview || {};
  const removes = (ui.scan?.endpoints || []).map((e) => [e.name, p[e.id]?.remove || 0]).filter(([, n]) => n);
  if (removes.length) {
    const ok = await confirmDialog(t('确认删除'), [
      t('将删除：{list}（文件夹连同内容）。', { list: removes.map(([n, c]) => t('{ep} {n} 项', { ep: n, n: c })).join(t('，')) }),
      t('Safari 写入前会自动完整备份；Chromium 浏览器里的删除可在书签管理器中用 ⌘Z 撤销（仅当前会话）。')], t('删除并同步'));
    if (!ok) return;
  }
  const btn = $('#btn-run');
  btn.disabled = true;
  btn.textContent = t('同步中…');
  try {
    const r = await call('run', { scanId: ui.scan.scanId, choices: ui.choices });
    await loadStatus();
    ui.scan = await call('scan');
    ui.choices = {};
    renderScan();
    renderResult(r);
  } catch (e) {
    showError(t('同步失败'), e);
  } finally {
    btn.disabled = false;
    btn.textContent = t('执行同步');
  }
}

function renderResult(r) {
  const el = $('#result');
  el.hidden = false;
  el.className = `card result ${r.ok ? 'ok' : 'fail'}`;
  const lines = Object.values(r.endpoints || {}).filter((e) => e.total).map((e) => h('div', {},
    t('{ep}：', { ep: e.name }),
    e.deferred ? t('{n} 个操作未写入——{why}', { n: e.deferred, why: e.reason || '' }) : t('已执行 {done}/{total}', { done: e.applied ?? 0, total: e.total }),
    e.backup ? [t(' · 备份 '), h('code', {}, e.backup)] : null,
    e.error ? h('span', { class: 'rm' }, ` · ${e.error.message}`) : null));
  el.replaceChildren(...[
    h('h3', {}, r.ok ? t('同步完成') : t('同步未完全成功')),
    lines.length ? h('div', {}, lines) : h('div', { class: 'muted' }, t('没有写入任何浏览器')),
    r.errors?.length ? h('ul', {}, r.errors.map((e) => h('li', {}, `${e.name ? `[${e.name}] ` : ''}${e.message}`))) : null,
    h('div', { class: 'muted small' }, t('剩余待决定 {n} 项 · 用时 {ms} ms', { n: r.remaining ?? '-', ms: r.ms })),
  ].filter(Boolean));
  el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function showError(title, e) {
  const el = $('#result');
  el.hidden = false;
  el.className = 'card result fail';
  el.replaceChildren(h('h3', {}, title), h('div', {}, `${e.code ? `[${e.code}] ` : ''}${e.message}`));
}

function confirmDialog(title, lines, okText = t('确定')) {
  const dlg = $('#dlg-confirm');
  $('#confirm-title').textContent = title;
  $('#confirm-body').replaceChildren(...lines.map((l) => h('p', {}, l)));
  $('#confirm-ok').textContent = okText;
  dlg.showModal();
  return new Promise((resolve) => {
    dlg.addEventListener('close', () => resolve(dlg.returnValue === 'ok'), { once: true });
  });
}

// ---- storage ---------------------------------------------------------------------------

const bytes = (n) => (n > 1048576 ? `${(n / 1048576).toFixed(1)} MB` : n > 1024 ? `${Math.round(n / 1024)} KB` : `${n || 0} B`);

async function loadStorageLine() {
  const el = $('#storage-line');
  if (!el) return;
  try {
    const s = await call('storage');
    const part = (label, d) => t('{label} {n} 个 · {size}', { label, n: d.count, size: bytes(d.bytes) });
    el.textContent = `${part(t('备份'), s.backups)}　${part(t('日志'), s.logs)}　${t('同步状态 {size}', { size: bytes(s.state.bytes) })}`;
  } catch (e) {
    el.textContent = t('读取失败：{msg}', { msg: e.message });
  }
}

async function cleanNow() {
  const dry = await call('clean', { what: 'all', dryRun: true });
  const n = (dry.backups?.removed || 0) + (dry.logs?.removed || 0) + (dry.logs?.truncated || 0);
  const size = (dry.backups?.bytes || 0) + (dry.logs?.bytes || 0);
  if (!n) { await confirmDialog(t('没有需要清理的文件'), [t('按当前的保留天数，备份和日志都还在保留期内。')], t('知道了')); return; }
  if (!await confirmDialog(t('清理旧文件？'), [t('将删除 {n} 个文件，释放约 {size}。最近几份备份不论多久都会保留。', { n, size: bytes(size) })], t('清理'))) return;
  const r = await call('clean', { what: 'all', dryRun: false });
  const done = (r.backups?.removed || 0) + (r.logs?.removed || 0) + (r.logs?.truncated || 0);
  await loadStorageLine();
  await confirmDialog(t('清理完成'), [t('已清理 {n} 个文件。', { n: done })], t('知道了'));
}

async function clearHistoryNow() {
  if (!await confirmDialog(t('清空同步历史？'), [t('只清掉历史记录，书签、备份和日志都不受影响。')], t('清空'))) return;
  await call('clearHistory');
  ui.history = [];
  if (!$('#history-view').hidden) renderHistory();
}

// ---- settings / history ------------------------------------------------------------------

async function openSettings() {
  const s = await call('settings');
  const eps = ui.status?.agent?.endpoints || [];
  const known = new Map(eps.map((e) => [e.id, e]));
  for (const id of Object.keys(s.endpoints || {})) if (!known.has(id)) known.set(id, { id, name: s.endpoints[id].name || id, online: false, kind: id === 'safari' ? 'safari' : 'chromium' });
  const row = (label, input, help) => h('label', { class: 'row' }, input, label, help ? h('small', {}, help) : null);
  const num = (id, v, min, max) => h('input', { type: 'number', id, value: v, min, max, step: 1 });
  const body = $('#settings-body');
  body.replaceChildren(
    h('h3', {}, t('同步规则')),
    row(t('常驻自动同步'), h('input', { type: 'checkbox', id: 'set-auto', checked: s.autoSync }),
      t('任一浏览器有改动后自动执行「新增 / 修改 / 移动 / 排序」。冲突始终等你确认；某个浏览器没开时，它的改动在下次打开后补上。')),
    h('label', { class: 'row' }, t('静默等待 '), num('set-delay', s.autoDelay ?? 5, 2, 600), t(' 秒后执行')),
    row(t('Safari 开着时也实时写入'), h('input', { type: 'checkbox', id: 'set-live', checked: s.safariWhileRunning !== false }),
      t('已实测：Safari 26 会立即显示写入的书签。关闭后，Safari 端的写入会等 Safari 退出再执行。')),
    h('label', { class: 'row' }, h('input', { type: 'checkbox', id: 'set-autodel', checked: s.autoDelete }), t('自动同步删除，单次最多 '), num('set-delmax', s.autoDeleteMax ?? 5, 1, 50), t(' 项'),
      h('small', {}, t('只自动删除「一端删了、其他端没改过」的项目。超过数量、有冲突，或检测到大量书签同时消失时，仍然等你确认。'))),
    row(t('同步文件夹内的排列顺序'), h('input', { type: 'checkbox', id: 'set-order', checked: s.syncOrder !== false })),
    h('label', { class: 'row' }, t('顺序以哪一端为准 '),
      h('select', { id: 'set-master' },
        h('option', { value: '' }, t('默认（最早连接的 Chrome）')),
        [...known.values()].map((e) => h('option', { value: e.id, selected: s.orderMaster === e.id ? true : null }, e.name))),
      h('small', {}, t('只调整了一两项位置时，以调整的一端为准；多端都改了或一次重排很多项时，以这里选的一端为准，并等你确认。'))),
    h('h3', {}, t('同步的浏览器')),
    h('table', { class: 'eps' },
      h('tr', {}, h('th', {}, t('启用')), h('th', {}, t('名称')), h('th', {}, t('同步方式')), h('th', {}, t('书签存储')), h('th', {}, t('状态'))),
      [...known.values()].map((e) => {
        const p = { enabled: true, mode: 'both', chromeStore: 'auto', ...(s.endpoints?.[e.id] || {}) };
        return h('tr', { 'data-ep': e.id },
          h('td', {}, h('input', { type: 'checkbox', class: 'ep-enabled', checked: p.enabled !== false })),
          h('td', {}, h('input', { type: 'text', class: 'ep-name', value: p.name || '', placeholder: e.name })),
          h('td', {}, h('select', { class: 'ep-mode' }, Object.entries(MODE).map(([k, v]) => h('option', { value: k, selected: p.mode === k ? true : null }, v)))),
          h('td', {}, e.kind === 'safari' ? h('span', { class: 'muted' }, '—')
            : h('select', { class: 'ep-store' },
              h('option', { value: 'auto', selected: p.chromeStore === 'auto' ? true : null }, t('自动')),
              h('option', { value: 'account', selected: p.chromeStore === 'account' ? true : null }, t('账号书签')),
              h('option', { value: 'local', selected: p.chromeStore === 'local' ? true : null }, t('仅此设备')))),
          h('td', { class: e.online ? '' : 'muted' }, e.online ? t('在线') : t('离线')));
      })),
    h('p', { class: 'muted small' }, t('只接收：这一端跟随其他端，但它自己的改动不会传出去；只发送：它的改动会传给其他端，但不接收别人的改动。')),
    h('h3', {}, t('界面语言')),
    h('label', { class: 'row' }, t('语言 '),
      h('select', { id: 'set-lang' },
        h('option', { value: 'system', selected: (s.language || 'system') === 'system' ? true : null }, t('跟随系统')),
        h('option', { value: 'zh', selected: s.language === 'zh' ? true : null }, '简体中文'),
        h('option', { value: 'en', selected: s.language === 'en' ? true : null }, 'English')),
      h('small', {}, t('保存后界面会刷新，App 和扩展共用这个设置。'))),
    h('h3', {}, t('存储与清理')),
    h('div', { id: 'storage-line', class: 'muted small' }, t('读取中…')),
    h('label', { class: 'row' }, t('备份保留 '), num('set-bdays', s.backupDays ?? 30, 1, 3650), t(' 天，日志保留 '), num('set-ldays', s.logDays ?? 30, 1, 3650), t(' 天'),
      h('small', {}, t('最近 {n} 份备份不论多久都保留；开启下面的每日清理后，后台服务每天按这里的天数清理一次。', { n: s.backupKeepMin ?? 10 }))),
    row(t('每天自动清理'), h('input', { type: 'checkbox', id: 'set-autoclean', checked: s.autoClean !== false })),
    h('div', { class: 'row tools' },
      h('button', { type: 'button', class: 'ghost', onclick: cleanNow }, t('立即清理…')),
      h('button', { type: 'button', class: 'ghost danger', onclick: clearHistoryNow }, t('清空同步历史…'))),
  );
  loadStorageLine();
  const dlg = $('#dlg-settings');
  dlg.showModal();
  dlg.addEventListener('close', async () => {
    if (dlg.returnValue !== 'ok') return;
    const endpoints = {};
    for (const tr of body.querySelectorAll('tr[data-ep]')) {
      const name = tr.querySelector('.ep-name').value.trim();
      endpoints[tr.dataset.ep] = {
        enabled: tr.querySelector('.ep-enabled').checked,
        mode: tr.querySelector('.ep-mode').value,
        name: name || undefined,
        ...(tr.querySelector('.ep-store') ? { chromeStore: tr.querySelector('.ep-store').value } : {}),
      };
    }
    const langBefore = s.language || 'system';
    await call('saveSettings', { patch: {
      autoSync: $('#set-auto').checked,
      autoDelay: Math.max(2, Number($('#set-delay').value) || 5),
      safariWhileRunning: $('#set-live').checked,
      autoDelete: $('#set-autodel').checked,
      autoDeleteMax: Math.min(50, Math.max(1, Number($('#set-delmax').value) || 5)),
      syncOrder: $('#set-order').checked,
      backupDays: Math.max(1, Number($('#set-bdays').value) || 30),
      logDays: Math.max(1, Number($('#set-ldays').value) || 30),
      autoClean: $('#set-autoclean').checked,
      language: $('#set-lang').value,
      orderMaster: $('#set-master').value || null,
      endpoints,
    } });
    if ((($('#set-lang') || {}).value || 'system') !== langBefore) { location.reload(); return; }
    await loadStatus();
  }, { once: true });
}

const OP_LABEL = { create: t('新增'), update: t('修改'), move: t('移动'), remove: t('删除'), reorder: t('顺序') };

function dayLabel(d) {
  const today = new Date();
  const same = (a, b) => a.toDateString() === b.toDateString();
  const yest = new Date(today.getTime() - 86400000);
  if (same(d, today)) return t('今天');
  if (same(d, yest)) return t('昨天');
  return d.toLocaleDateString(locale(), { month: 'long', day: 'numeric' });
}

function epSummary(e) {
  if (e.error) return t('{ep} 失败', { ep: e.name });
  if (e.deferred) return t('{ep} 延后 {n}', { ep: e.name, n: e.deferred });
  return `${e.name} ${e.applied ?? 0}${e.applied === e.total ? '' : `/${e.total}`}`;
}

function historyDetail(r) {
  const eps = Object.values(r.endpoints || {}).filter((e) => e.total);
  const rows = eps.map((e) => h('div', { class: 'hist-ep' },
    h('b', {}, e.name),
    h('span', { class: 'muted' }, Object.entries(e.ops || {}).map(([k, n]) => `${OP_LABEL[k] || k} ${n}`).join(' · ') || '—'),
    e.deferred ? h('span', { class: 'chip warn' }, t('延后 {n}{why}', { n: e.deferred, why: e.reason ? `（${e.reason}）` : '' })) : null,
    e.error ? h('span', { class: 'chip bad' }, e.error.message || t('失败')) : null,
    e.backup ? h('button', { type: 'button', class: 'ghost small', onclick: () => call('reveal', { what: 'backup', name: e.backup.split('/').pop() }) }, t('显示备份')) : null,
  ));
  const notes = [];
  if (r.ms) notes.push(t('耗时 {s} 秒', { s: (r.ms / 1000).toFixed(1) }));
  if (r.remaining) notes.push(t('仍有 {n} 项待确认', { n: r.remaining }));
  for (const e of r.errors || []) notes.push(e);
  return h('div', { class: 'hist-detail' }, rows, notes.length ? h('p', { class: 'muted small' }, notes.join(' · ')) : null);
}

function renderHistory() {
  const box = $('#history');
  const all = ui.history || [];
  const mode = ui.historyFilter || 'all';
  const rows = all.filter((r) => (mode === 'manual' ? !r.auto : mode === 'failed' ? !r.ok : true));
  box.replaceChildren();
  if (!rows.length) {
    box.append(h('p', { class: 'muted' }, all.length ? t('这个筛选下没有记录') : t('还没有同步记录')));
    return;
  }
  let day = null;
  for (const r of rows) {
    const d = new Date(r.at);
    const label = dayLabel(d);
    if (label !== day) {
      day = label;
      box.append(h('div', { class: 'hist-day' }, label));
    }
    const eps = Object.values(r.endpoints || {}).filter((e) => e.total);
    const detail = historyDetail(r);
    detail.hidden = true;
    const row = h('div', { class: `hist-row${r.ok ? '' : ' bad'}`, role: 'button', tabindex: '0',
      onclick: () => {
        detail.hidden = !detail.hidden;
        row.classList.toggle('open', !detail.hidden);
      } },
      h('span', { class: 'hist-time' }, d.toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' })),
      h('span', { class: 'hist-how' }, r.auto ? t('自动') : t('手动')),
      h('span', { class: 'hist-eps' }, eps.map(epSummary).join(' · ') || '—'),
      h('span', { class: 'hist-result' }, r.ok ? '✓' : (r.errors || []).join(t('；')) || t('失败')),
    );
    box.append(row, detail);
  }
}

const HIDE_WHEN_HISTORY = ['#setup', '#scan-meta-row', '#warnings', '#filters', '#empty', '#list', '#result', '#bar'];

async function openHistory() {
  ui.hiddenBefore = Object.fromEntries(HIDE_WHEN_HISTORY.map((sel) => [sel, $(sel).hidden]));
  for (const sel of HIDE_WHEN_HISTORY) $(sel).hidden = true;
  $('#history-view').hidden = false;
  markView('history');
  try {
    ui.history = await call('history');
  } catch (e) {
    ui.history = [];
    showError(t('读取历史失败'), e);
  }
  renderHistory();
}

/// Highlights whichever of the two top buttons matches the view below.
function markView(view) {
  $('#btn-history').classList.toggle('on', view === 'history');
  $('#btn-scan').classList.toggle('primary', view !== 'history');
  $('#btn-scan').classList.toggle('ghost', view === 'history');
}

function closeHistory() {
  $('#history-view').hidden = true;
  markView('scan');
  for (const [sel, was] of Object.entries(ui.hiddenBefore || {})) $(sel).hidden = was;
  ui.hiddenBefore = null;
}

function toggleHistory() {
  if ($('#history-view').hidden) openHistory();
  else closeHistory();
}

// ---- wiring --------------------------------------------------------------------------------

$('#btn-scan').addEventListener('click', doScan);
$('#btn-run').addEventListener('click', doRun);
$('#btn-settings').addEventListener('click', openSettings);
$('#btn-history').addEventListener('click', toggleHistory);
$('#btn-history-back').addEventListener('click', closeHistory);
for (const b of document.querySelectorAll('#history-filter button')) {
  b.addEventListener('click', () => {
    ui.historyFilter = b.dataset.hist;
    for (const o of document.querySelectorAll('#history-filter button')) o.classList.toggle('on', o === b);
    renderHistory();
  });
}
$('#btn-backups').addEventListener('click', () => call('reveal', { what: 'backups' }));
$('#btn-logs').addEventListener('click', () => call('reveal', { what: 'logs' }));
$('#btn-restore-order').addEventListener('click', () => $('#file-restore').click());
$('#file-restore').addEventListener('change', async (e) => {
  const file = e.target.files?.[0];
  e.target.value = '';
  if (!file) return;
  try {
    const html = await file.text();
    const dry = await call('restoreOrder', { html, dryRun: true });
    $('#dlg-settings').close();
    const ok = await confirmDialog(t('按备份恢复本浏览器的顺序'), [
      t('备份文件：{name}', { name: file.name }),
      t('将调整 {folders} 个文件夹的顺序，共 {moves} 次移动；备份中匹配到 {matched} 项，本浏览器里有 {unmatched} 项备份中没有（保持原顺序，排在各自文件夹末尾）。', { folders: dry.reordered, moves: dry.moves, matched: dry.matched, unmatched: dry.unmatched }),
      t('只调整同一文件夹内的顺序，不会新增、删除或跨文件夹移动任何书签。完成后重新扫描，其他端的顺序在列表里确认后同步。'),
    ], t('恢复顺序'));
    if (!ok) return;
    const r = await call('restoreOrder', { html, dryRun: false });
    await doScan();
    const el = $('#result');
    el.hidden = false;
    el.className = 'card result ok';
    el.replaceChildren(h('h3', {}, t('顺序已按备份恢复')),
      h('div', {}, t('调整了 {folders} 个文件夹（{moves} 次移动）。列表里的「排序」项确认后点「执行同步」，其他端即会一致。', { folders: r.reordered, moves: r.moves })));
  } catch (err) {
    showError(t('恢复顺序失败'), err);
  }
});

$('#btn-reset').addEventListener('click', async () => {
  const ok = await confirmDialog(t('重置同步状态'), [
    t('会清空映射关系和统一版本（旧状态会留存在 StateHistory 中）。'),
    t('下次扫描将按「首次同步」处理：相同书签自动配对，不会删除任何书签。'),
  ], t('重置'));
  if (!ok) return;
  await call('resetState');
  ui.scan = null;
  $('#list').replaceChildren();
  $('#bar').hidden = true;
  $('#filters').hidden = true;
});
for (const b of document.querySelectorAll('#type-filter button')) {
  b.addEventListener('click', () => {
    ui.filter = b.dataset.type;
    for (const x of document.querySelectorAll('#type-filter button')) x.classList.toggle('on', x === b);
    renderList();
  });
}
$('#search').addEventListener('input', (e) => { ui.query = e.target.value.trim(); renderList(); });
for (const b of document.querySelectorAll('[data-bulk]')) {
  b.addEventListener('click', () => bulk(ui.scan?.items || [], b.dataset.bulk));
}

backend.onEvent((m) => {
  if (['safari.running', 'agent.disconnected', 'endpoints.changed', 'pending'].includes(m.event)) loadStatus();
  if (m.event === 'autoRun' && m.result && !m.result.skipped) loadStatus();
  if (m.event === 'changed' && ui.scan) {
    $('#scan-meta-row').hidden = false;
    $('#scan-meta').textContent = t('书签有新变化，建议重新扫描');
  }
});

// Language first: the whole interface (and the markup in index.html) is Chinese by
// default and swapped to English through en.json.
(async () => {
  let setting = 'system';
  try { setting = (await call('settings')).language || 'system'; } catch { /* agent down */ }
  await useLang(setting);
  buildLabels();
  translateDom();
  loadStatus();
})();
