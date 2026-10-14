import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AgentClient } from '../agent-client.js';

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
