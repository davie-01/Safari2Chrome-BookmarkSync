import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AgentClient, CHUNK_TTL_MS, MAX_PENDING_MESSAGES } from '../agent-client.js';

test('agent client reassembles chunked replies and routes events', async () => {
  const listeners = { msg: [], disc: [] };
  const port = {
    onMessage: { addListener: (f) => listeners.msg.push(f) },
    onDisconnect: { addListener: (f) => listeners.disc.push(f) },
    postMessage: (m) => {
      const payload = JSON.stringify({ id: m.id, ok: true, result: { big: 'x'.repeat(3000), zh: '中文' } });
      const b = Buffer.from(payload, 'utf8');
      const parts = [b.subarray(0, 1000), b.subarray(1000, 2500), b.subarray(2500)];
      queueMicrotask(() => {
        listeners.msg.forEach((f) => f({ event: 'safari.changed' }));
        [2, 0, 1].forEach((seq) => listeners.msg.forEach((f) => f({ chunk: { cid: 'c1', seq, total: 3, b64: parts[seq].toString('base64') } })));
      });
    },
  };
  const client = new AgentClient({ connectNative: () => port });
  const events = [];
  client.onEvent((e) => events.push(e.event));
  const r = await client.request('safari.read');
  assert.equal(r.big.length, 3000);
  assert.equal(r.zh, '中文');
  assert.deepEqual(events, ['safari.changed']);
});

test('agent client answers agent RPCs', async () => {
  const listeners = { msg: [], disc: [] };
  const sent = [];
  const port = { onMessage: { addListener: (f) => listeners.msg.push(f) }, onDisconnect: { addListener: (f) => listeners.disc.push(f) }, postMessage: (m) => sent.push(m) };
  const client = new AgentClient({ connectNative: () => port });
  client.onRpc(async (method, params) => { if (method === 'boom') throw Object.assign(new Error('bad'), { code: 'x' }); return { echo: params }; });
  client.connect();
  listeners.msg.forEach((f) => f({ rpc: 1, method: 'read', params: { a: 1 } }));
  listeners.msg.forEach((f) => f({ rpc: 2, method: 'boom' }));
  await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(sent, [{ rpcReply: 1, ok: true, result: { echo: { a: 1 } } }, { rpcReply: 2, ok: false, error: { code: 'x', message: 'bad' } }]);
});

function chunkClient() {
  const listeners = { msg: [], disc: [] };
  const port = { onMessage: { addListener: (f) => listeners.msg.push(f) }, onDisconnect: { addListener: (f) => listeners.disc.push(f) }, postMessage() {} };
  const client = new AgentClient({ connectNative: () => port });
  client.connect();
  const got = [];
  client.onEvent((e) => got.push(e));
  const send = (chunk) => listeners.msg.forEach((f) => f({ chunk }));
  const part = (s) => Buffer.from(s).toString('base64');
  return { client, send, part, got, disconnect: () => listeners.disc.forEach((f) => f()) };
}

test('agent client drops an incomplete message after the TTL, even with no further traffic', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { client, send, part } = chunkClient();
  send({ cid: 'a', seq: 0, total: 2, b64: part('{"event":') });
  assert.equal(client.chunks.size, 1);
  t.mock.timers.tick(CHUNK_TTL_MS - 1);
  assert.equal(client.chunks.size, 1);
  t.mock.timers.tick(1);
  assert.equal(client.chunks.size, 0);
});

test('agent client completes, cancels the expiry, and validates chunks', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { client, send, part, got, disconnect } = chunkClient();
  send({ cid: 'ok', seq: 1, total: 2, b64: part('"x"}') });
  send({ cid: 'ok', seq: 0, total: 2, b64: part('{"event":') });
  assert.deepEqual(got, [{ event: 'x' }]);
  assert.equal(client.chunks.size, 0);
  t.mock.timers.tick(CHUNK_TTL_MS); // nothing left to fire
  // malformed: bad seq/total, total changing mid-message, bad base64, undecodable JSON
  for (const c of [{ cid: 'b', seq: 2, total: 2, b64: '' }, { cid: 'b', seq: 0, total: 0, b64: '' }, { cid: 'b', seq: 0, total: 1e6, b64: '' }, { seq: 0, total: 1, b64: '' }]) send(c);
  assert.equal(client.chunks.size, 0);
  send({ cid: 'c', seq: 0, total: 2, b64: part('{') });
  send({ cid: 'c', seq: 1, total: 3, b64: part('}') });
  assert.equal(client.chunks.size, 0);
  send({ cid: 'd', seq: 0, total: 1, b64: '%%%' });
  send({ cid: 'e', seq: 0, total: 1, b64: part('{nope') });
  assert.equal(client.chunks.size, 0);
  assert.equal(got.length, 1);
  // at most MAX_PENDING_MESSAGES half-received messages; the oldest goes first
  for (let i = 0; i <= MAX_PENDING_MESSAGES; i++) send({ cid: `p${i}`, seq: 0, total: 2, b64: part('{') });
  assert.deepEqual([...client.chunks.keys()], Array.from({ length: MAX_PENDING_MESSAGES }, (_, i) => `p${i + 1}`));
  disconnect();
  assert.equal(client.chunks.size, 0);
});
