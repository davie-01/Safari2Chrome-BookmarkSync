import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canonicalize } from '../engine/url.js';

const SYNTH = [
  'https://Example.COM', 'HTTP://Example.com:80/a/./b/../c?x=1#F', 'https://例子.测试/路径?q=中文#锚点', 'https://a.com/a b', "https://a.com/?a b'c",
  'http://user:pa ss@host.com:8080/p', 'https://[::1]:8080/x', 'http://0x7f.1/', 'javascript:alert(1 + 2)', 'javascript:void(0)  ', 'mailto:Me@Example.com',
  'chrome://settings/', 'about:blank', 'data:text/html,<b>hi</b>', 'file:///Users/x/a b.html', 'https://a.com/%7Euser/%e4%b8%ad', 'https://a.com/a%2e%2e/b',
  'https://a.com\\b\\c', '  https://a.com/ \n', 'https://ÄÖÜ.de/', 'https://a.com?', 'https://a.com#', 'https://a.com/😀?😀#😀', 'obsidian://open?vault=x y',
];

// Node < 24 predates the 2025 WHATWG change that encodes a space ending an opaque path
// before '?' or '#'; bring its output up to the current spec.
const OLD_SPACE_RULE = new URL('javascript:a ?').href === 'javascript:a ?';
const node = (u) => {
  let h;
  try { h = new URL(u).href; } catch { return null; }
  if (OLD_SPACE_RULE && /^[a-z][a-z0-9+.-]*:[^/]/i.test(h)) h = h.replace(/ (?=[?#])/, '%20');
  return h;
};

test('url: canonicalize matches WHATWG URL on synthetic cases', () => {
  for (const u of SYNTH) assert.equal(canonicalize(u), node(u), u);
});

test('url: canonicalize matches WHATWG URL on random bookmark-like URLs', () => {
  let seed = 7;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const chars = ['a', 'B', '中', '文', ' ', '%20', '%e4', '.', '..', '/', '?', '#', '&', '=', "'", '"', '<', '`', '{', '|', '~', '😀', '+', ':', '@', '%', '-', '_'];
  const word = () => Array.from({ length: 1 + Math.floor(rnd() * 6) }, () => pick(chars)).join('');
  let n = 0;
  for (let i = 0; i < 3000; i++) {
    const scheme = pick(['https', 'http', 'HTTPS', 'ftp', 'javascript', 'mailto', 'chrome', 'file']);
    const host = pick(['example.com', 'EXAMPLE.org', '例子.中国', 'a.b.c', 'localhost', '127.0.0.1', 'x.com:8080', 'x.com:443', 'y.com:80']);
    const u = `${scheme}:${scheme.startsWith('java') || scheme === 'mailto' ? '' : '//'}${host}/${word()}/${word()}${rnd() < 0.5 ? '?' + word() : ''}${rnd() < 0.3 ? '#' + word() : ''}`;
    const want = node(u);
    if (want === null) continue;
    assert.equal(canonicalize(u), want, u);
    n++;
  }
  assert.ok(n > 2000);
});
