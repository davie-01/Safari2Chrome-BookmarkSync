// Native messaging client for the local agent (via the bmsync native host relay).

export const HOST_NAME = 'com.mars.davie_01.bookmarksync';

/** Chunks of a message that never completes are dropped after this long. */
export const CHUNK_TTL_MS = 2 * 60 * 1000;
/** Reassembly limits: anything beyond them is not a message the host would send. */
export const MAX_MESSAGE_BYTES = 64 * 1024 * 1024;
export const MAX_PENDING_MESSAGES = 4;
const MAX_CHUNK_B64 = 1024 * 1024; // a host frame is under Chrome's 1 MB
const MAX_CHUNKS = Math.ceil(MAX_MESSAGE_BYTES / (600 * 1024)) + 1; // host chunks 600 KB

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
      this._dropChunks();
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
    if (m && m.chunk) { this._onChunk(m.chunk); return; }
    if (m && m.rpc !== undefined) { this._answerRpc(m); return; }
    if (m && m.event) { this._emit(m); return; }
    const p = this.pending.get(m?.id);
    if (!p) return;
    this.pending.delete(m.id);
    clearTimeout(p.timer);
    if (m.ok) p.resolve(m.result);
    else p.reject(Object.assign(new Error(m.error?.message || 'agent error'), { code: m.error?.code || 'agentError' }));
  }

  _onChunk({ cid, seq, total, b64 } = {}) {
    const valid = typeof cid === 'string' && Number.isInteger(total) && total >= 1 && total <= MAX_CHUNKS
      && Number.isInteger(seq) && seq >= 0 && seq < total && typeof b64 === 'string' && b64.length <= MAX_CHUNK_B64;
    let entry = valid ? this.chunks.get(cid) : null;
    if (!valid || (entry && entry.total !== total)) {
      console.warn('dropping malformed message chunk', { cid, seq, total });
      if (typeof cid === 'string') this._dropChunks(cid);
      return;
    }
    if (!entry) {
      if (this.chunks.size >= MAX_PENDING_MESSAGES) this._dropChunks(this.chunks.keys().next().value); // oldest
      // a message whose remaining chunks never come (host died mid-way) goes after a while
      entry = { total, parts: new Array(total), got: 0, len: 0, timer: setTimeout(() => this._dropChunks(cid), CHUNK_TTL_MS) };
      this.chunks.set(cid, entry);
    }
    if (entry.parts[seq] !== undefined) return;
    // decode on arrival: the base64 text is not kept alongside the bytes
    let bin;
    try { bin = atob(b64); } catch { this._dropChunks(cid); return; }
    if (entry.len + bin.length > MAX_MESSAGE_BYTES) { console.warn('dropping oversized message', cid); this._dropChunks(cid); return; }
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    entry.parts[seq] = bytes;
    entry.len += bytes.length;
    entry.got++;
    if (entry.got < total) return;
    this._dropChunks(cid);
    const all = new Uint8Array(entry.len);
    let off = 0;
    for (const b of entry.parts) { all.set(b, off); off += b.length; }
    let msg;
    try { msg = JSON.parse(new TextDecoder().decode(all)); } catch { console.warn('dropping undecodable message', cid); return; }
    this._onMessage(msg);
  }

  /** Forgets one partly received message, or all of them. */
  _dropChunks(cid) {
    for (const [k, e] of this.chunks) {
      if (cid !== undefined && k !== cid) continue;
      clearTimeout(e.timer);
      this.chunks.delete(k);
    }
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
