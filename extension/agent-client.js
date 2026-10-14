// Native messaging client for the local agent (via the bmsync native host relay).

export const HOST_NAME = 'com.mars.davie_01.bookmarksync';

export class AgentClient {
  constructor({ connectNative = (n) => chrome.runtime.connectNative(n), timeoutMs = 60000 } = {}) {
    this.connectNative = connectNative;
    this.timeoutMs = timeoutMs;
    this.port = null;
    this.nextId = 1;
    this.pending = new Map();
    this.chunks = new Map();
    this.listeners = new Set();
    this.lastError = null;
    this.rpcHandler = null;
    this.onConnectHooks = [];
  }

  /** handler(method, params) -> Promise<result>; answers RPCs the agent sends to this endpoint. */
  onRpc(handler) { this.rpcHandler = handler; }

  /** Called after every (re)connect, e.g. to announce this endpoint. */
  onConnect(fn) { this.onConnectHooks.push(fn); }

  get connected() { return !!this.port; }

  onEvent(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }

  connect() {
    if (this.port) return this.port;
    const port = this.connectNative(HOST_NAME);
    this.port = port;
    port.onMessage.addListener((m) => this._onMessage(m));
    for (const fn of this.onConnectHooks) { try { fn(); } catch (e) { console.error(e); } }
    port.onDisconnect.addListener(() => {
      const err = (globalThis.chrome && chrome.runtime.lastError && chrome.runtime.lastError.message) || 'native host disconnected';
      this.lastError = err;
      this.port = null;
      for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(Object.assign(new Error(err), { code: 'hostDisconnected' })); }
      this.pending.clear();
      this.chunks.clear();
      this._emit({ event: 'agent.disconnected', message: err });
    });
    return port;
  }

  disconnect() {
    if (this.port) { try { this.port.disconnect(); } catch { /* ignore */ } }
    this.port = null;
  }

  request(type, params = {}, { timeoutMs } = {}) {
    this.connect();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(Object.assign(new Error(`agent request ${type} timed out`), { code: 'timeout' }));
      }, timeoutMs ?? this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer, type });
      try {
        this.port.postMessage({ id, type, ...params });
      } catch (e) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(e);
      }
    });
  }

  _onMessage(m) {
    if (m && m.chunk) {
      const { cid, seq, total, b64 } = m.chunk;
      let entry = this.chunks.get(cid);
      if (!entry) { entry = { parts: new Array(total), got: 0 }; this.chunks.set(cid, entry); }
      if (entry.parts[seq] === undefined) { entry.parts[seq] = b64; entry.got++; }
      if (entry.got === total) {
        this.chunks.delete(cid);
        const bytes = entry.parts.map((p) => Uint8Array.from(atob(p), (c) => c.charCodeAt(0)));
        const len = bytes.reduce((a, b) => a + b.length, 0);
        const all = new Uint8Array(len);
        let off = 0;
        for (const b of bytes) { all.set(b, off); off += b.length; }
        this._onMessage(JSON.parse(new TextDecoder().decode(all)));
      }
      return;
    }
    if (m && m.rpc !== undefined) { this._answerRpc(m); return; }
    if (m && m.event) { this._emit(m); return; }
    const p = this.pending.get(m?.id);
    if (!p) return;
    this.pending.delete(m.id);
    clearTimeout(p.timer);
    if (m.ok) p.resolve(m.result);
    else p.reject(Object.assign(new Error(m.error?.message || 'agent error'), { code: m.error?.code || 'agentError' }));
  }

  async _answerRpc(m) {
    let reply;
    try {
      if (!this.rpcHandler) throw Object.assign(new Error('no rpc handler'), { code: 'noHandler' });
      reply = { rpcReply: m.rpc, ok: true, result: await this.rpcHandler(m.method, m.params) };
    } catch (e) {
      reply = { rpcReply: m.rpc, ok: false, error: { code: e.code || 'error', message: e.message } };
    }
    try { this.port?.postMessage(reply); } catch (e) { console.warn('rpc reply failed', e); }
  }

  /** Fire-and-forget event to the agent. */
  event(name, extra = {}) {
    try { this.connect(); this.port.postMessage({ event: name, ...extra }); } catch (e) { console.warn(e); }
  }

  _emit(ev) { for (const fn of this.listeners) { try { fn(ev); } catch (e) { console.error(e); } } }
}
