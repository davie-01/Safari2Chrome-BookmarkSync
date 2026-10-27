import { canonicalize } from './url.js';
// Small shared helpers. Pure, no browser APIs.

export const ROOTS = ['root:bar', 'root:other'];
export const ROOT_TITLES = { 'root:bar': '书签栏', 'root:other': '其他书签 / Safari 顶层' };

export function isRoot(key) {
  return ROOTS.includes(key);
}

/** Canonical form used ONLY for comparison (never written back). Mirrors WHATWG/GURL closely enough. */
export function canonUrl(u) {
  if (u == null) return null;
  const s = String(u).trim();
  if (typeof globalThis.URL === 'function' && !globalThis.__BMS_NO_URL) {
    try { return new URL(s).href; } catch { return s; }
  }
  return canonicalize(s) ?? s; // JavaScriptCore (macOS agent): no URL class
}

export function newSafariUUID() {
  const c = globalThis.crypto;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID().toUpperCase();
  // Fallback (tests on old runtimes)
  const h = [...Array(32)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20)}`.toUpperCase();
}

export const other = (side) => (side === 's' ? 'c' : 's');
export const sideName = (side) => (side === 's' ? 'Safari' : 'Chrome');

/**
 * Longest common subsequence of two key arrays; returns a Set of keys in the LCS.
 * Keys are unique within each array, so the LCS is the longest increasing run of the
 * b-positions of a's keys: O(n log n) time and O(n) memory, even for huge folders.
 */
export function lcsSet(a, b) {
  const posInB = new Map(b.map((k, j) => [k, j]));
  const keys = [], pos = [];
  for (const k of a) {
    const j = posInB.get(k);
    if (j !== undefined) { keys.push(k); pos.push(j); }
  }
  // tails[l] = index (into pos) of the smallest tail of an increasing run of length l + 1
  const tails = [];
  const prev = new Int32Array(pos.length);
  for (let i = 0; i < pos.length; i++) {
    let lo = 0, hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (pos[tails[mid]] < pos[i]) lo = mid + 1; else hi = mid;
    }
    prev[i] = lo > 0 ? tails[lo - 1] : -1;
    tails[lo] = i;
  }
  const out = new Set();
  for (let i = tails.length ? tails[tails.length - 1] : -1; i >= 0; i = prev[i]) out.add(keys[i]);
  return out;
}

export function sameOrder(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
