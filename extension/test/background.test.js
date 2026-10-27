import { test } from 'node:test';
import assert from 'node:assert/strict';

// A fake `chrome` just big enough for background.js to start, with a scriptable native host.
function fakeChrome({ onPost } = {}) {
  const listeners = () => { const fns = []; return { addListener: (f) => fns.push(f), fns }; };
  const store = (data = {}) => ({
    data,
    get: async (k) => (k in data ? { [k]: data[k] } : {}),
    set: async (o) => { Object.assign(data, o); },
  });
  const alarms = new Map();
  const log = { connects: 0, alarmsCreated: [], alarmsCleared: [], ports: [] };
  const chrome = {
    runtime: {
      onMessage: listeners(), onStartup: listeners(), onInstalled: listeners(),
      getManifest: () => ({ version: 'test' }), getURL: (p) => p, sendMessage: async () => {}, lastError: null,
      connectNative: () => {
        log.connects++;
        const port = { onMessage: listeners(), onDisconnect: listeners(), disconnect() {}, postMessage: (m) => onPost?.(port, m) };
        log.ports.push(port);
        return port;
      },
    },
    storage: { local: store(), session: store() },
    bookmarks: Object.fromEntries(['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onChildrenReordered', 'onImportEnded'].map((k) => [k, listeners()])),
    alarms: {
      onAlarm: listeners(),
      create: async (name, info) => { alarms.set(name, info); log.alarmsCreated.push([name, info]); },
      get: async (name) => (alarms.has(name) ? { name, ...alarms.get(name) } : undefined),
      clear: async (name) => { log.alarmsCleared.push(name); return alarms.delete(name); },
      fire: async (name) => { alarms.delete(name); for (const f of chrome.alarms.onAlarm.fns) await f({ name }); },
    },
    action: { onClicked: listeners(), setBadgeBackgroundColor: async () => {}, setBadgeText: async () => {} },
  };
  return { chrome, log, alarms };
}

const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
let instance = 0;
const load = () => import(`../background.js?i=${++instance}`);

test('background: an unreachable host is retried with a growing wait, then left to events', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  t.mock.method(Math, 'random', () => 0.5); // no jitter
  const { chrome, log, alarms } = fakeChrome();
  globalThis.chrome = chrome;
  const hostGone = async () => { for (const f of log.ports.at(-1).onDisconnect.fns) f(); await settle(); };
  await load();
  await settle();
  assert.equal(log.connects, 1);
  assert.deepEqual(log.alarmsCreated, []); // no periodic alarm any more
  assert.ok(log.alarmsCleared.includes('keepalive')); // and the old one is removed

  await hostGone(); // the host could not start
  t.mock.timers.tick(2999); await settle();
  assert.equal(log.connects, 1);
  t.mock.timers.tick(1); await settle();
  assert.equal(log.connects, 2); // after 3 s
  await hostGone();
  t.mock.timers.tick(10000); await settle();
  assert.equal(log.connects, 3); // after 10 s
  // from 30 s on: a one-shot alarm (it wakes a stopped worker), never a periodic one
  for (const [i, minutes] of [[4, 0.5], [5, 1], [6, 5], [7, 5], [8, 5], [9, 5]]) {
    await hostGone();
    assert.deepEqual(log.alarmsCreated.at(-1), ['reconnect', { delayInMinutes: minutes }]);
    await chrome.alarms.fire('reconnect'); await settle();
    assert.equal(log.connects, i);
  }
  await hostGone(); // 8 failures: stop; the next event (browser start, an edit, the UI) tries again
  assert.equal(alarms.size, 0);
  assert.ok(log.alarmsCreated.every(([, info]) => !info.periodInMinutes));
  t.mock.timers.tick(3600 * 1000); await settle();
  assert.equal(log.connects, 9);
});

test('background: with the host up and the agent down, nothing retries until "agent.available"', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let agentUp = false;
  const hellos = [];
  const { chrome, log, alarms } = fakeChrome({
    onPost: (port, m) => queueMicrotask(() => {
      if (m.type === 'endpoint.hello') hellos.push(m);
      const reply = agentUp && m.type === 'endpoint.hello'
        ? { id: m.id, ok: true, result: { endpoint: { id: m.endpoint.id, name: 'Chrome' } } }
        : { id: m.id, ok: false, error: { code: 'agentUnavailable', message: 'agent down' } };
      for (const f of port.onMessage.fns) f(reply);
    }),
  });
  globalThis.chrome = chrome;
  await load();
  await settle();
  assert.equal(hellos.length, 1); // announced on connect, answered "unavailable"
  t.mock.timers.tick(3600 * 1000); await settle();
  assert.equal(log.connects, 1);
  assert.equal(hellos.length, 1); // no retries while the host waits for the agent
  assert.equal(alarms.size, 0);

  agentUp = true;
  for (const f of log.ports[0].onMessage.fns) f({ event: 'agent.available' });
  await settle();
  assert.equal(hellos.length, 2);
  assert.equal((await chrome.storage.local.get('endpoint')).endpoint?.name, 'Chrome');
  assert.equal(chrome.storage.session.data.reconnectFailures, 0);
});
