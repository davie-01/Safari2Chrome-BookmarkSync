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

/** Longest common subsequence of two key arrays; returns a Set of keys in the LCS (keys are unique). */
export function lcsSet(a, b) {
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out = new Set();
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { out.add(a[i]); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) i++;
    else j++;
  }
  return out;
}

export function sameOrder(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
