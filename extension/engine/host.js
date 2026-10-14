// Entry point of the engine bundle that runs inside the macOS agent (JavaScriptCore).
// The agent provides one function:
//   __nativeCall(method: string, paramsJSON: string, resolve(json: string), reject(code, message))
// and calls BMS.handle(method, paramsJSON) -> Promise<json string>.

import { Coordinator, DEFAULT_SETTINGS } from './coordinator.js';
import { canonicalize } from './url.js';

if (typeof globalThis.structuredClone !== 'function') {
  globalThis.structuredClone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
}
if (!globalThis.crypto || typeof globalThis.crypto.randomUUID !== 'function') {
  globalThis.crypto = { ...(globalThis.crypto || {}), randomUUID: () => globalThis.__uuid() };
}

const native = (method, params) => new Promise((resolve, reject) => {
  globalThis.__nativeCall(method, JSON.stringify(params === undefined ? null : params),
    (json) => resolve(json ? JSON.parse(json) : null),
    (code, message) => reject(Object.assign(new Error(message || code), { code })));
});

function endpointFrom(d) {
  return {
    ...d,
    read: (prefs) => native('endpoint.read', { id: d.id, prefs }),
    apply: (ops, opts) => native('endpoint.apply', { id: d.id, ops, opts }),
  };
}

const coordinator = new Coordinator({
  store: {
    load: () => native('store.load'),
    save: (state, expectedRevision) => native('store.save', { state, expectedRevision }).then((r) => r.revision),
  },
  settings: {
    load: () => native('settings.load'),
    save: (settings) => native('settings.save', { settings }),
  },
  kv: {
    get: (key) => native('kv.get', { key }),
    set: (key, value) => native('kv.set', { key, value }),
  },
  endpoints: {
    list: async () => ((await native('endpoints.list')) || []).map(endpointFrom),
  },
});

const handlers = {
  ping: async () => ({ pong: true }),
  clearHistory: async () => { await coordinator.deps.kv.set('history', []); return { ok: true }; },
  settings: () => coordinator.settings(),
  saveSettings: (p) => coordinator.saveSettings(p.patch || {}),
  defaults: async () => DEFAULT_SETTINGS,
  scan: () => coordinator.scan(),
  preview: (p) => coordinator.preview(p.scanId, p.choices),
  run: (p) => coordinator.run(p.scanId, p.choices || {}),
  autoRun: () => coordinator.autoRun(),
  history: async () => (await native('kv.get', { key: 'history' })) || [],
  pending: async () => (await native('kv.get', { key: 'pending' })) || null,
  lastRun: async () => (await native('kv.get', { key: 'lastRun' })) || null,
  isRunning: async () => ({ running: coordinator.running }),
  canonicalize: async (p) => ({ href: canonicalize(p.url) }),
};

globalThis.BMS = {
  version: 2,
  async handle(method, paramsJSON) {
    const h = handlers[method];
    if (!h) throw Object.assign(new Error(`unknown engine method ${method}`), { code: 'unknownMethod' });
    const params = paramsJSON ? JSON.parse(paramsJSON) : {};
    const result = await h(params || {});
    return JSON.stringify(result === undefined ? null : result);
  },
};
