// Heavier randomized run (not part of the default suite): node test/stress.mjs [seeds] [rounds]
import assert from 'node:assert/strict';
import { env, cycle, assertInSync, choose } from './helpers.js';
import { randomEdit } from './fuzz-lib.js';
const seeds = +process.argv[2] || 50, rounds = +process.argv[3] || 80;
function rng(seed) { return () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648); }
let fails = 0;
for (let seed = 1; seed <= seeds; seed++) {
  const rnd = rng(seed * 7919);
  const e = env();
  for (let i = 0; i < 5; i++) e.safari.add('root:bar', `seed${i}`, `https://seed${i}.test/`);
  try {
    await cycle(e);
    for (let round = 0; round < rounds; round++) {
      const n = 1 + Math.floor(rnd() * 4);
      for (let k = 0; k < n; k++) await randomEdit(e, rnd, `${round}_${k}`);
      await cycle(e, { choose: (items) => Object.fromEntries(items.map((it) => [it.id, rnd() < 0.4 ? 'ignore' : it.choices[Math.floor(rnd() * it.choices.length)].id])) });
      let r;
      for (let pass = 0; pass < 2; pass++) r = await cycle(e, { choose: choose({ 'del:': 'apply', conflict: 'useS' }) });
      assert.deepEqual(r.after.items.map((i) => i.id), [], `round ${round} leftovers`);
      await assertInSync(e);
    }
  } catch (err) { fails++; console.log(`seed ${seed}:`, err.message.split('\n').slice(0, 14).join('\n')); if (fails > 3) break; }
}
console.log(fails ? `FAILED ${fails}` : `ok ${seeds} seeds x ${rounds} rounds`);
