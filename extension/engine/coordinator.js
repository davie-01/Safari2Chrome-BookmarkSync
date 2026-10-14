// Transport-agnostic sync coordinator: scan -> preview -> run -> commit across all online
// endpoints. Runs inside the BookmarkSync agent (JavaScriptCore) in production and in
// Node for tests. Everything it touches comes in through `deps`.

import { runMulti, commitEndpoint, migrateState, adoptEndpoint, originOf, emptyState } from './multi.js';
import { descendants } from './tree.js';
import { newSafariUUID } from './util.js';

/** How many sync runs the history keeps (oldest dropped). */
export const HISTORY_MAX = 100;

/** Counts a plan's operations by type, for the history detail view. */
export function countOps(ops) {
  const out = {};
  for (const op of ops) out[op.op] = (out[op.op] || 0) + 1;
  return out;
}

export const DEFAULT_SETTINGS = {
  autoSync: false,
  autoDelay: 5,
  syncOrder: true,
  safariWhileRunning: true,
  autoDelete: false,
  autoDeleteMax: 5,
  orderMaster: null,        // endpoint id whose order wins when unclear; null = first Chrome
  backupDays: 30,           // retention for Safari backups (the newest backupKeepMin are always kept)
  logDays: 30,              // retention for log files
  backupKeepMin: 10,
  autoClean: true,          // the agent prunes once a day
  language: 'system',       // interface language: system | zh | en (app and extension share it)
  endpoints: {},            // id -> { enabled, mode: both|receive|send, chromeStore, name }
};

/**
 * deps:
 *   store:     { load(): Promise<{state, revision}>, save(state, expectedRevision): Promise<number> }
 *   settings:  { load(): Promise<object|null>, save(obj): Promise<void> }
 *   endpoints: { list(): Promise<Endpoint[]> }
 *     Endpoint = { id, kind: 'safari'|'chromium', browser, name, online,
 *                  read(): Promise<{ tree, fingerprint }>,
 *                  apply(ops, opts): Promise<{ applied?, created?, deferred?, reason?, error? }> }
 *   kv:        { get(k), set(k, v) }   small UI-facing records (lastRun, history, pending)
 */
export class Coordinator {
  constructor(deps, { now = () => Date.now() } = {}) {
    this.deps = deps;
    this.now = now;
    this.scans = new Map();
    this.seq = 0;
    this.running = false;
  }

  async settings() {
    const s = (await this.deps.settings.load()) || {};
    return { ...DEFAULT_SETTINGS, ...s, endpoints: { ...(s.endpoints || {}) } };
  }

  async saveSettings(patch) {
    const cur = await this.settings();
    const next = { ...cur, ...patch };
    if (patch.endpoints) {
      next.endpoints = { ...cur.endpoints };
      for (const [id, p] of Object.entries(patch.endpoints)) next.endpoints[id] = { ...(cur.endpoints[id] || {}), ...p };
    }
    await this.deps.settings.save(next);
    return next;
  }

  epPrefs(settings, id) {
    return { enabled: true, mode: 'both', chromeStore: 'auto', ...(settings.endpoints[id] || {}) };
  }

  /** Online, enabled endpoints in processing order (order master first, then Safari, then first-seen). */
  async activeEndpoints(settings, state) {
    const all = await this.deps.endpoints.list();
    const master = this.orderMasterId(settings, all, state);
    const seen = (id) => state.endpoints[id]?.firstSeenAt ?? 0;
    return all
      .filter((e) => e.online && this.epPrefs(settings, e.id).enabled)
      .sort((a, b) => (b.id === master) - (a.id === master) || (b.kind === 'safari') - (a.kind === 'safari') || seen(a.id) - seen(b.id));
  }

  orderMasterId(settings, all, state) {
    if (settings.orderMaster) return settings.orderMaster;
    const chrome = all.filter((e) => e.browser === 'chrome').sort((a, b) => (state.endpoints[a.id]?.firstSeenAt ?? 0) - (state.endpoints[b.id]?.firstSeenAt ?? 0));
    return chrome[0]?.id || all.find((e) => e.kind === 'chromium')?.id || 'safari';
  }

  async loadState() {
    const { state, revision } = await this.deps.store.load();
    return { state: migrateState(state) || emptyState(), revision };
  }

  async snapshot() {
    const settings = await this.settings();
    const { state, revision } = await this.loadState();
    const eps = await this.activeEndpoints(settings, state);
    const reads = await Promise.all(eps.map((e) => e.read(this.epPrefs(settings, e.id)).then((r) => ({ ok: true, r }), (err) => ({ ok: false, err }))));
    const online = [];
    const failed = [];
    eps.forEach((e, i) => {
      if (reads[i].ok) online.push({ ep: e, read: reads[i].r });
      else failed.push({ id: e.id, name: e.name, code: reads[i].err?.code, message: reads[i].err?.message });
    });
    for (const { ep } of online) adoptEndpoint(state, ep);
    settings.orderMaster = this.orderMasterId(settings, online.map((o) => o.ep), state);
    return { settings, state, revision, online, failed };
  }

  compute(snap, choices) {
    const endpoints = snap.online.map(({ ep, read }) => ({
      id: ep.id,
      name: ep.name,
      mode: this.epPrefs(snap.settings, ep.id).mode,
      tree: read.tree,
      pair: snap.state.endpoints[ep.id]?.pair,
      idGen: ep.kind === 'safari' ? () => newSafariUUID() : null,
    }));
    return runMulti({ hub: snap.state.hub, endpoints, choices, settings: snap.settings });
  }

  view(snap, r) {
    const names = Object.fromEntries(snap.online.map(({ ep }) => [ep.id, ep.name]));
    for (const [id, e] of Object.entries(snap.state.endpoints)) names[id] ??= e.name;
    return {
      items: r.items.map((x) => serializeMultiItem(x, names)),
      preview: r.summary,
      warnings: r.warnings.filter((w) => w.code === 'massMissing').map((w) => ({ ...w, epName: names[w.ep] })),
      endpoints: snap.online.map(({ ep }) => ({ id: ep.id, name: ep.name, kind: ep.kind, browser: ep.browser, mode: this.epPrefs(snap.settings, ep.id).mode })),
      offline: snap.failed,
      firstSync: snap.online.some(({ ep }) => !Object.keys(snap.state.endpoints[ep.id]?.pair?.mappings || {}).length),
    };
  }

  async scan() {
    const snap = await this.snapshot();
    const r = this.compute(snap, {});
    const scanId = `scan-${++this.seq}`;
    this.scans.set(scanId, { snap, at: this.now() });
    for (const k of [...this.scans.keys()].slice(0, -3)) this.scans.delete(k);
    return { scanId, ...this.view(snap, r) };
  }

  preview(scanId, choices) {
    const s = this.scans.get(scanId);
    if (!s) throw Object.assign(new Error('scan expired, rescan'), { code: 'staleScan' });
    return this.view(s.snap, this.compute(s.snap, choices || {}));
  }

  async run(scanId, choices = {}, { auto = false } = {}) {
    if (this.running) throw Object.assign(new Error('a sync is already running'), { code: 'busy' });
    const s = this.scans.get(scanId);
    if (!s) throw Object.assign(new Error('scan expired, rescan'), { code: 'staleScan' });
    this.running = true;
    const started = this.now();
    const result = { at: started, auto, endpoints: {}, errors: [], ok: false };
    try {
      const snap = s.snap;
      // freshness: nothing may have changed since the scan
      const fresh = await this.snapshot();
      const fp = (x) => Object.fromEntries(x.online.map(({ ep, read }) => [ep.id, read.fingerprint]));
      if (JSON.stringify(fp(fresh)) !== JSON.stringify(fp(snap)) || fresh.revision !== snap.revision) {
        throw Object.assign(new Error('bookmarks changed since the scan, rescan first'), { code: 'changedSinceScan' });
      }
      const r = this.compute(snap, choices);
      result.plan = r.summary;

      // execute: every endpoint independently
      const settings = snap.settings;
      const exec = {};
      for (const { ep } of snap.online) {
        const ops = r.perEp[ep.id].ops;
        const rec = { total: ops.length, ops: countOps(ops) };
        if (ops.length) {
          try {
            const res = await ep.apply(ops, { ...this.epPrefs(settings, ep.id), allowWhileSafariRunning: settings.safariWhileRunning !== false });
            if (res?.deferred) { rec.deferred = ops.length; rec.reason = res.reason; }
            else if (res?.error) { rec.applied = res.done ?? 0; rec.error = res.error; result.errors.push({ ep: ep.id, name: ep.name, ...res.error }); }
            else rec.applied = res?.applied ?? ops.length;
            if (res?.backup) rec.backup = res.backup;
            exec[ep.id] = res || {};
          } catch (e) {
            rec.error = { code: e.code, message: e.message };
            result.errors.push({ ep: ep.id, name: ep.name, code: e.code, message: e.message });
            exec[ep.id] = { failed: true };
          }
        }
        result.endpoints[ep.id] = { name: ep.name, ...rec };
      }

      // commit: hub is authoritative; each endpoint advances only where it now agrees
      const state = snap.state;
      state.hub = r.hub;
      for (const { ep } of snap.online) {
        let after;
        try { after = (await ep.read(this.epPrefs(settings, ep.id))).tree; } catch { continue; }
        const x = exec[ep.id] || {};
        const results = { applied: !!(x && !x.failed && !x.deferred && !x.error && (r.perEp[ep.id].ops.length)), created: x.created || {} };
        const pair = commitEndpoint({ pair: state.endpoints[ep.id].pair, perEp: r.perEp[ep.id], hubTree: r.hub.tree, epTreeAfter: after, results, now: this.now() });
        state.endpoints[ep.id] = { ...state.endpoints[ep.id], name: ep.name, pair, lastSyncAt: this.now() };
      }
      await this.deps.store.save(state, snap.revision);

      // verify
      const again = await this.snapshot();
      const r2 = this.compute(again, {});
      result.remaining = r2.items.length;
      const pendingWrites = Object.fromEntries(Object.entries(r2.summary).filter(([k]) => k !== 'hub').map(([k, v]) => [k, v.total]));
      result.pendingWrites = pendingWrites;
      await this.deps.kv.set('pending', {
        at: this.now(),
        items: r2.items.length,
        conflicts: r2.items.filter((x) => x.multi || x.it.type === 'conflict' || x.it.type === 'deleteConflict').length,
        heldOrders: r2.items.filter((x) => !x.multi && x.it.type === 'order' && x.it.suspicious).length,
        pendingWrites,
      });
      result.ok = result.errors.length === 0;
    } catch (e) {
      result.errors.push({ code: e.code, message: e.message });
    } finally {
      this.running = false;
      this.scans.delete(scanId);
      result.ms = this.now() - started;
      await this.deps.kv.set('lastRun', result);
      // A run that wrote nothing and hit no trouble is not worth a history line.
      const wroteOrFailed = result.errors.length > 0
        || Object.values(result.endpoints).some((e) => (e.applied || 0) > 0 || e.deferred || e.error);
      if (wroteOrFailed) {
        const hist = (await this.deps.kv.get('history')) || [];
        hist.unshift({
          at: result.at, auto, ok: result.ok, ms: result.ms,
          endpoints: result.endpoints,
          errors: result.errors.map((e) => e.message),
          remaining: result.remaining,
        });
        await this.deps.kv.set('history', hist.slice(0, HISTORY_MAX));
      }
    }
    return result;
  }

  /** Resident mode policy over the decision list. */
  async autoRun() {
    if (this.running) return { skipped: 'busy' };
    const settings = await this.settings();
    const scan = await this.scan();
    const choices = {};
    const deletes = scan.items.filter((x) => x.type === 'delete' && x.origin === 'c' && x.choices.includes('apply'));
    const delNodes = deletes.reduce((a, x) => a + (x.count || 1), 0);
    const allowDeletes = settings.autoDelete && deletes.length > 0 && !scan.warnings.length && delNodes <= (settings.autoDeleteMax || 5);
    for (const x of scan.items) {
      let c = 'ignore';
      if ((x.type === 'modify' || x.type === 'create') && x.default === 'apply') c = 'apply';
      else if (x.type === 'delete' && x.origin === 'c' && allowDeletes) c = 'apply';
      else if (x.type === 'order' && !x.suspicious && x.default !== 'ignore') c = x.default;
      choices[x.id] = c;
    }
    const pv = this.preview(scan.scanId, choices);
    const writes = Object.values(pv.preview).reduce((a, v) => a + (v.total || 0), 0);
    const heldDeletes = deletes.length && !allowDeletes ? delNodes : 0;
    if (!writes) {
      await this.deps.kv.set('pending', { at: this.now(), items: scan.items.length, conflicts: scan.items.filter((x) => x.type.includes('onflict')).length, heldDeletes, heldOrders: scan.items.filter((x) => x.type === 'order' && x.suspicious).length });
      this.scans.delete(scan.scanId);
      return { skipped: 'nothing', pending: scan.items.length, heldDeletes };
    }
    const r = await this.run(scan.scanId, choices, { auto: true });
    r.heldDeletes = heldDeletes;
    return r;
  }
}

/** Plain JSON for the UI. Pair sides: s = hub (the other endpoints), c = this endpoint. */
export function serializeMultiItem(x, names) {
  if (x.multi) {
    const g = x.multi;
    const info = g.eps.map((e) => {
      const it = e.it;
      return { ep: e.ep, name: names[e.ep] || e.ep, deleted: e.deleted, fields: e.fields, title: it.c?.title, url: it.c?.url, path: it.c?.path };
    });
    const b = g.eps[0].it.b;
    return {
      id: x.full, type: 'multiConflict', key: g.key, kind: g.eps[0].it.kind,
      endpoints: info, b,
      s: g.eps[0].it.s, // hub (last agreed) view
      choices: [...g.eps.map((e) => `use:${e.ep}`), 'ignore'], default: 'ignore', choice: x.choice,
    };
  }
  const { it, ep, diff } = x;
  const out = {
    id: x.full,
    ep, epName: names[ep] || ep,
    against: x.against, againstName: x.against ? names[x.against] || x.against : null,
    origin: originOf(it),
    type: it.type, key: it.key, kind: it.kind,
    from: it.from, deletedOn: it.deletedOn, fields: it.fields, firstSync: it.firstSync,
    s: it.s, c: it.c, b: it.b, count: it.count,
    changedBy: it.changedBy, suspicious: it.suspicious, moved: it.moved,
    choices: it.choices.map((c) => c.id), default: it.default, choice: x.choice,
  };
  if (it.type === 'create' || it.type === 'delete' || it.type === 'deleteConflict') {
    const side = it.type === 'create' ? it.from : it.deletedOn === 's' ? 'c' : 's';
    const rootId = it[side]?.id;
    const idx = diff.ctx.idx[side];
    if (rootId && it.kind === 'folder' && idx.byId.has(rootId)) {
      const lines = [];
      const base = idx.byId.get(rootId).depth;
      for (const d of descendants(idx, rootId)) {
        if (lines.length >= 200) { lines.push({ more: true }); break; }
        const r = idx.byId.get(d);
        lines.push({ depth: r.depth - base, kind: r.kind, title: r.title, url: r.url });
      }
      out.subtree = lines;
    }
  }
  return out;
}
