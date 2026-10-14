// URL canonicalization for comparison only (never written back). In browsers and Node the
// native WHATWG `URL` is used; inside the macOS agent's JavaScriptCore there is no `URL`,
// so this file implements the parts of the WHATWG URL serializer that bookmark URLs hit:
// scheme/host case, default ports, dot segments, percent-encoding sets, IDNA (punycode).
// test/url.test.js checks it against Node's URL on real and synthetic bookmark URLs.

const SPECIAL = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21', 'file:': '' };

const hex = (b) => '%' + b.toString(16).toUpperCase().padStart(2, '0');
const utf8 = (cp) => {
  const s = String.fromCodePoint(cp);
  const out = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
    } else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
};

function encodeSet(extra) {
  const set = new Set([...extra].map((c) => c.charCodeAt(0)));
  return (cp) => cp < 0x20 || cp > 0x7e || set.has(cp);
}
const C0 = encodeSet('');
const FRAGMENT = encodeSet(' "<>`');
const QUERY = encodeSet(' "#<>');
const SPECIAL_QUERY = encodeSet(' "#<>\'');
const PATH = encodeSet(' "#<>?`{}');
const USERINFO = encodeSet(' "#<>?`{}/:;=@[\\]^|');

function pct(str, inSet) {
  let out = '';
  for (const ch of str) {
    const cp = ch.codePointAt(0);
    out += inSet(cp) ? utf8(cp).map(hex).join('') : ch;
  }
  return out;
}

// ---- punycode (RFC 3492) ------------------------------------------------------------
function punyEncode(input) {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  const cps = [...input].map((c) => c.codePointAt(0));
  let n = 128, delta = 0, bias = 72;
  let out = cps.filter((c) => c < 128).map((c) => String.fromCharCode(c)).join('');
  const b = out.length;
  let h = b;
  if (b) out += '-';
  const digit = (d) => String.fromCharCode(d + 22 + 75 * (d < 26));
  const adapt = (d, numPoints, first) => {
    d = first ? Math.floor(d / damp) : d >> 1;
    d += Math.floor(d / numPoints);
    let k = 0;
    while (d > ((base - tMin) * tMax) >> 1) { d = Math.floor(d / (base - tMin)); k += base; }
    return k + Math.floor(((base - tMin + 1) * d) / (d + skew));
  };
  while (h < cps.length) {
    const m = Math.min(...cps.filter((c) => c >= n));
    delta += (m - n) * (h + 1);
    n = m;
    for (const c of cps) {
      if (c < n) delta++;
      if (c === n) {
        let q = delta;
        for (let k = base; ; k += base) {
          const t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias;
          if (q < t) break;
          out += digit(t + ((q - t) % (base - t)));
          q = Math.floor((q - t) / (base - t));
        }
        out += digit(q);
        bias = adapt(delta, h + 1, h === b);
        delta = 0;
        h++;
      }
    }
    delta++; n++;
  }
  return out;
}

function pctDecode(s) {
  return s.replace(/(%[0-9a-fA-F]{2})+/g, (m) => {
    try { return decodeURIComponent(m); } catch { return m; }
  });
}

function hostToASCII(host) {
  let h = pctDecode(host);
  if (typeof h.normalize === 'function') h = h.normalize('NFKC');
  h = h.toLowerCase().replace(/[。．｡]/g, '.');
  if (/[\x00-\x20#%/:<>?@[\\\]^|]/.test(h)) return null; // forbidden host code points
  return h.split('.').map((label) => (/[^\x00-\x7f]/.test(label) ? 'xn--' + punyEncode(label) : label)).join('.');
}

function ipv4(host) {
  const parts = host.split('.');
  if (parts[parts.length - 1] === '') parts.pop();
  if (!parts.length || parts.length > 4) return host;
  const nums = [];
  for (const p of parts) {
    let v;
    if (/^0[xX][0-9a-fA-F]*$/.test(p)) v = p.length === 2 ? 0 : parseInt(p.slice(2), 16);
    else if (/^0[0-7]+$/.test(p)) v = parseInt(p.slice(1), 8);
    else if (/^(0|[1-9][0-9]*)$/.test(p)) v = parseInt(p, 10);
    else return host; // not an IPv4 address
    nums.push(v);
  }
  let n = 0;
  for (let i = 0; i < nums.length - 1; i++) { if (nums[i] > 255) return null; n = n * 256 + nums[i]; }
  const last = nums[nums.length - 1];
  const rem = 5 - nums.length;
  if (last >= 256 ** rem) return null;
  n = n * 256 ** rem + last;
  return [n >>> 24 & 255, n >>> 16 & 255, n >>> 8 & 255, n & 255].join('.');
}

function resolvePath(segments, special) {
  const out = [];
  const isDot = (s) => s === '.' || s.toLowerCase() === '%2e';
  const isDotDot = (s) => ['..', '.%2e', '%2e.', '%2e%2e'].includes(s.toLowerCase());
  segments.forEach((seg, i) => {
    const last = i === segments.length - 1;
    if (isDotDot(seg)) {
      const had = out.length > 0;
      out.pop();
      if (last && (special || had)) out.push(''); // non-special: `/..` on an empty path stays empty
    }
    else if (isDot(seg)) { if (last) out.push(''); }
    else out.push(seg);
  });
  return out;
}

/** Returns the canonical href, or null when the string is not a valid absolute URL. */
export function canonicalize(input) {
  let s = String(input).replace(/^[\x00-\x20]+|[\x00-\x20]+$/g, '').replace(/[\t\n\r]/g, '');
  const m = /^([a-zA-Z][a-zA-Z0-9+.\-]*):/.exec(s);
  if (!m) return null;
  const scheme = m[1].toLowerCase() + ':';
  let rest = s.slice(m[0].length);
  const special = scheme in SPECIAL;
  let fragment = null, query = null;
  const hashAt = rest.indexOf('#');
  if (hashAt >= 0) { fragment = rest.slice(hashAt + 1); rest = rest.slice(0, hashAt); }

  if (special) {
    rest = rest.replace(/\\/g, '/');
    const qAt = rest.indexOf('?');
    if (qAt >= 0) { query = rest.slice(qAt + 1); rest = rest.slice(0, qAt); }
    if (scheme === 'file:') {
      let host = '';
      let path = rest;
      if (/^\/\//.test(rest)) {
        const r = rest.slice(2);
        const slash = r.indexOf('/');
        host = slash < 0 ? r : r.slice(0, slash);
        path = slash < 0 ? '' : r.slice(slash);
        const hh = host ? hostToASCII(host) : '';
        if (hh === null) return null;
        host = hh === 'localhost' ? '' : hh;
      }
      const segs = resolvePath(path.replace(/^\//, '').split('/'), true);
      return 'file://' + host + '/' + segs.map((x) => pct(x, PATH)).join('/')
        + (query !== null ? '?' + pct(query, SPECIAL_QUERY) : '') + (fragment !== null ? '#' + pct(fragment, FRAGMENT) : '');
    }
    rest = rest.replace(/^\/*/, '');
    const slash = rest.indexOf('/');
    let authority = slash < 0 ? rest : rest.slice(0, slash);
    const pathPart = slash < 0 ? '' : rest.slice(slash);
    let userinfo = '';
    const at = authority.lastIndexOf('@');
    if (at >= 0) {
      const ui = authority.slice(0, at);
      authority = authority.slice(at + 1);
      const colon = ui.indexOf(':');
      const user = pct(colon < 0 ? ui : ui.slice(0, colon), USERINFO);
      const pass = colon < 0 ? '' : pct(ui.slice(colon + 1), USERINFO);
      if (user || pass) userinfo = user + (pass ? ':' + pass : '') + '@';
    }
    let host = authority, port = '';
    const pm = /^(.*?)(?::(\d*))?$/.exec(authority.startsWith('[') ? authority.replace(/^(\[[^\]]*\])/, '$1') : authority);
    if (authority.startsWith('[')) {
      const end = authority.indexOf(']');
      if (end < 0) return null;
      host = authority.slice(0, end + 1).toLowerCase();
      const after = authority.slice(end + 1);
      if (after && !/^:\d*$/.test(after)) return null;
      port = after.slice(1);
    } else {
      const c = authority.lastIndexOf(':');
      if (c >= 0) { host = authority.slice(0, c); port = authority.slice(c + 1); if (!/^\d*$/.test(port)) return null; }
      void pm;
      if (!host) return null;
      const h = hostToASCII(host);
      if (h === null || !h) return null;
      const v4 = ipv4(h);
      if (v4 === null) return null;
      host = v4;
    }
    if (port !== '') {
      const pn = parseInt(port, 10);
      if (pn > 65535) return null;
      port = String(pn) === SPECIAL[scheme] ? '' : String(pn);
    }
    const segs = resolvePath(pathPart.replace(/^\//, '').split('/'), true);
    const path = '/' + segs.map((x) => pct(x, PATH)).join('/');
    return scheme + '//' + userinfo + host + (port ? ':' + port : '') + path
      + (query !== null ? '?' + pct(query, SPECIAL_QUERY) : '') + (fragment !== null ? '#' + pct(fragment, FRAGMENT) : '');
  }

  // non-special schemes (javascript:, mailto:, chrome:, about:, data:, ...)
  const qAt = rest.indexOf('?');
  if (qAt >= 0) { query = rest.slice(qAt + 1); rest = rest.slice(0, qAt); }
  let head = '';
  if (rest.startsWith('//')) {
    const r = rest.slice(2);
    const slash = r.indexOf('/');
    let authority = slash < 0 ? r : r.slice(0, slash);
    const path = slash < 0 ? '' : r.slice(slash);
    const at = authority.lastIndexOf('@');
    let userinfo = '';
    if (at >= 0) { userinfo = pct(authority.slice(0, at), USERINFO) + '@'; authority = authority.slice(at + 1); }
    head = '//' + userinfo + pct(authority, C0);
    const segs = path ? resolvePath(path.replace(/^\//, '').split('/'), false) : null;
    rest = segs && segs.length ? '/' + segs.map((x) => pct(x, PATH)).join('/') : '';
  } else if (rest.startsWith('/')) {
    const segs = resolvePath(rest.replace(/^\//, '').split('/'), false);
    rest = '/' + segs.map((x) => pct(x, PATH)).join('/');
  } else {
    // opaque path: trailing spaces are stripped when nothing follows; otherwise a final
    // space right before '?' or '#' is written as %20 (WHATWG URL, 2025 revision)
    if (query === null && fragment === null) rest = rest.replace(/ +$/, '');
    rest = pct(rest, C0);
    if ((query !== null || fragment !== null) && rest.endsWith(' ')) rest = rest.slice(0, -1) + '%20';
  }
  return scheme + head + rest + (query !== null ? '?' + pct(query, QUERY) : '') + (fragment !== null ? '#' + pct(fragment, FRAGMENT) : '');
}
