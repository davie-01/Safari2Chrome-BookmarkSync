// MV3 service worker. This browser profile is one sync endpoint: the BookmarkSync agent on
// the Mac runs the sync engine and calls us (RPC over native messaging) to read and write
// this profile's bookmarks. We also report bookmark changes and proxy the UI page's
// requests to the agent.

import { AgentClient } from './agent-client.js';
import { parseBookmarkHtml, restoreChromeOrder } from './backup-order.js';
import { normalizeChrome, executeChrome } from './chrome-adapter.js';

const agent = new AgentClient();
const local = {
  get: async (k) => (await chrome.storage.local.get(k))[k],
  set: async (k, v) => chrome.storage.local.set({ [k]: v }),
};

// ---- identity ------------------------------------------------------------------

async function endpointId() {
  let id = await local.get('endpointId');
  if (!id) {
    id = `cr-${crypto.randomUUID()}`;
    await local.set('endpointId', id);
  }
  return id;
}

function browserFromUA() {
  const brands = (navigator.userAgentData?.brands || []).map((b) => b.brand);
  const ua = navigator.userAgent || '';
  if (brands.includes('Microsoft Edge') || /Edg\//.test(ua)) return 'edge';
  if (brands.includes('Brave')) return 'brave';
  if (brands.includes('Opera') || /OPR\//.test(ua)) return 'opera';
  if (/Vivaldi/.test(ua)) return 'vivaldi';
  if (brands.includes('Google Chrome')) return 'chrome';
  return 'chromium';
}

let announced = null;
async function announce() {
  try {
    const r = await agent.request('endpoint.hello', {
      endpoint: { id: await endpointId(), browser: browserFromUA(), ua: navigator.userAgent, extVersion: chrome.runtime.getManifest().version },
    }, { timeoutMs: 15000 });
    announced = r.endpoint;
    await local.set('endpoint', r.endpoint);
  } catch (e) {
    announced = null;
    console.warn('endpoint.hello failed', e);
  }
}
agent.onConnect(() => { announce(); });

// ---- executor (RPC from the agent) ---------------------------------------------------

let suppressUntil = 0; // ignore bookmark events caused by our own writes

function fingerprint(str) {
  // FNV-1a 64-bit over the JSON of the normalized tree
  let h1 = 0x811c9dc5, h2 = 0x01000193;
  for (let i = 0; i < str.length; i++) {
    const c = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 16777619) >>> 0;
    h2 = Math.imul(h2 ^ c, 2246822519) >>> 0;
  }
  return `${h1.toString(16).padStart(8, '0')}${h2.toString(16).padStart(8, '0')}:${str.length}`;
}

agent.onRpc(async (method, params) => {
  const store = params?.chromeStore || params?.prefs?.chromeStore || 'auto';
  switch (method) {
    case 'read': {
      const n = normalizeChrome((await chrome.bookmarks.getTree())[0], store);
      return { tree: n.tree, fingerprint: fingerprint(JSON.stringify(n.tree)), store: n.store };
    }
    case 'apply': {
      const { rootIds } = normalizeChrome((await chrome.bookmarks.getTree())[0], store);
      suppressUntil = Number.POSITIVE_INFINITY;
      try {
        const r = await executeChrome(params.ops || [], chrome.bookmarks, rootIds);
        return { applied: r.done, done: r.done, created: r.created, error: r.error || null };
      } finally {
        suppressUntil = Date.now() + 1500;
      }
    }
    case 'ping':
      return { pong: true };
    case 'restoreOrder': {
      // The App has no bookmarks API of its own; it asks us to reorder from an HTML export.
      const backup = parseBookmarkHtml(params.html || '');
      if (!backup.bar && !backup.other) throw Object.assign(new Error('没有在文件里找到书签栏或其他书签'), { code: 'badBackup' });
      const { rootIds } = normalizeChrome((await chrome.bookmarks.getTree())[0], store);
      if (params.dryRun) return restoreChromeOrder(chrome.bookmarks, rootIds, backup, { dryRun: true });
      suppressUntil = Number.POSITIVE_INFINITY;
      try { return await restoreChromeOrder(chrome.bookmarks, rootIds, backup); }
      finally { suppressUntil = Date.now() + 1500; reportChange('restoreOrder'); }
    }
    default:
      throw Object.assign(new Error(`unknown rpc ${method}`), { code: 'unknownRpc' });
  }
});

// ---- change reporting ---------------------------------------------------------------

let changeTimer = null;
function reportChange(kind) {
  if (Date.now() < suppressUntil) return;
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => agent.event('bookmarks.changed', { kind }), 300);
  toUI({ event: 'changed', reason: kind });
}
for (const ev of ['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onChildrenReordered']) {
  chrome.bookmarks[ev].addListener(() => reportChange(ev));
}
chrome.bookmarks.onImportEnded?.addListener(() => reportChange('import'));

// ---- UI messaging -----------------------------------------------------------------

const engine = (method, params = {}, timeoutMs = 60000) => agent.request(`engine.${method}`, { params }, { timeoutMs });

const handlers = {
  status: async () => {
    const out = { endpointId: await endpointId(), endpoint: announced || (await local.get('endpoint')) || null };
    try { out.agent = await agent.request('hello', {}, { timeoutMs: 8000 }); } catch (e) { out.agentError = { code: e.code || 'error', message: e.message }; }
    if (out.agent) {
      try { out.settings = await engine('settings'); } catch { out.settings = {}; }
      try { out.pending = await engine('pending'); } catch { /* ignore */ }
      if (!announced) announce();
    }
    return out;
  },
  scan: () => engine('scan', {}, 120000),
  preview: (m) => engine('preview', { scanId: m.scanId, choices: m.choices }, 120000),
  run: async (m) => { const r = await engine('run', { scanId: m.scanId, choices: m.choices }, 600000); refreshBadge(); return r; },
  settings: () => engine('settings'),
  saveSettings: (m) => engine('saveSettings', { patch: m.patch }),
  history: () => engine('history'),
  resetState: () => agent.request('state.reset'),
  reveal: (m) => agent.request('reveal', { what: m.what }),
  backups: () => agent.request('backups.list'),
  storage: () => agent.request('storage.stats'),
  clean: (m) => agent.request('storage.clean', { what: m.what, dryRun: m.dryRun }),
  clearHistory: () => engine('clearHistory'),
  restoreOrder: async (m) => {
    const backup = parseBookmarkHtml(m.html);
    if (!backup.bar && !backup.other) throw Object.assign(new Error('没有在文件里找到书签栏或其他书签'), { code: 'badBackup' });
    let store = 'auto';
    try { store = (await engine('settings'))?.endpoints?.[await endpointId()]?.chromeStore || 'auto'; } catch { /* default */ }
    const { rootIds } = normalizeChrome((await chrome.bookmarks.getTree())[0], store);
    if (m.dryRun) return restoreChromeOrder(chrome.bookmarks, rootIds, backup, { dryRun: true });
    suppressUntil = Number.POSITIVE_INFINITY; // not an edit to sync mid-way; report once at the end
    try { return await restoreChromeOrder(chrome.bookmarks, rootIds, backup); }
    finally { suppressUntil = Date.now() + 1500; reportChange('restoreOrder'); }
  },
};

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  const h = handlers[msg?.type];
  if (!h) return false;
  Promise.resolve()
    .then(() => h(msg))
    .then((result) => sendResponse({ ok: true, result }))
    .catch((e) => sendResponse({ ok: false, error: { code: e.code || 'error', message: e.message } }));
  return true;
});

function toUI(ev) {
  chrome.runtime.sendMessage({ type: 'event', ...ev }).catch(() => {});
}

agent.onEvent((ev) => {
  if (ev.event === 'agent.disconnected') {
    announced = null;
    toUI(ev);
    setTimeout(() => { try { agent.connect(); } catch { /* retry on alarm */ } }, 3000);
    return;
  }
  if (ev.event === 'pending') refreshBadge(ev.pending);
  if (ev.event === 'autoRun') refreshBadge();
  toUI(ev);
});

chrome.action.onClicked.addListener(async () => {
  const url = chrome.runtime.getURL('ui/index.html');
  const tabs = await chrome.tabs.query({ url });
  if (tabs.length) {
    await chrome.tabs.update(tabs[0].id, { active: true });
    await chrome.windows.update(tabs[0].windowId, { focused: true });
  } else {
    await chrome.tabs.create({ url });
  }
});

// ---- keep the endpoint online ------------------------------------------------------

// An open native messaging port keeps the MV3 service worker alive; the alarm reconnects
// after the agent restarts or the browser suspended us.
chrome.alarms.create('keepalive', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(async (a) => {
  if (a.name !== 'keepalive') return;
  if (!agent.connected || !announced) { try { agent.connect(); if (!announced) await announce(); } catch { /* agent down */ } }
});

async function refreshBadge(pending) {
  let p = pending;
  if (p === undefined) { try { p = await engine('pending'); } catch { return; } }
  const n = (p?.items || 0);
  await chrome.action.setBadgeBackgroundColor({ color: p?.conflicts || p?.heldDeletes || p?.heldOrders ? '#d97706' : '#2563eb' });
  await chrome.action.setBadgeText({ text: n ? String(Math.min(n, 999)) : '' });
}

function start() {
  try { agent.connect(); } catch (e) { console.warn(e); }
  refreshBadge();
}
chrome.runtime.onStartup.addListener(start);
chrome.runtime.onInstalled.addListener(start);
start();
