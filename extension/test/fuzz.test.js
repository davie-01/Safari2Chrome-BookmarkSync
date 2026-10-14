import { test } from 'node:test';
import assert from 'node:assert/strict';
import { env, cycle, assertInSync, choose } from './helpers.js';
import { randomEdit } from './fuzz-lib.js';

function rng(seed) { return () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648); }

for (const seed of [1, 7, 42, 99, 1234, 31337, 2024, 555]) {
  test(`fuzz seed ${seed}: multi-edit rounds converge with no leftovers`, async () => {
    const rnd = rng(seed);
    const e = env();
    for (let i = 0; i < 6; i++) e.safari.add('root:bar', `seed${i}`, `https://seed${i}.test/`);
    await cycle(e);
    for (let round = 0; round < 60; round++) {
      const n = 1 + Math.floor(rnd() * 3);
      for (let k = 0; k < n; k++) await randomEdit(e, rnd, `${round}_${k}`);
      const r = await cycle(e, { choose: choose({ 'del:': 'apply', conflict: rnd() < 0.5 ? 'useS' : 'useC' }) });
      assert.deepEqual(r.plan.warnings, [], `round ${round} warnings`);
      assert.deepEqual(r.after.items.map((i) => i.id), [], `round ${round} leftovers`);
      await assertInSync(e);
    }
  });
}

for (const direction of ['s2c', 'c2s']) {
  test(`fuzz one-way ${direction}: source side is never written; choosing all target-side choices converges`, async () => {
    const rnd = rng(direction === 's2c' ? 11 : 13);
    const e = env();
    for (let i = 0; i < 6; i++) e.safari.add('root:bar', `seed${i}`, `https://seed${i}.test/`);
    await cycle(e);
    const srcSide = direction === 's2c' ? 's' : 'c';
    for (let round = 0; round < 50; round++) {
      for (let k = 0; k < 2; k++) await randomEdit(e, rnd, `${round}_${k}`);
      const r = await cycle(e, {
        direction,
        choose: (items) => Object.fromEntries(items.map((it) => [it.id, it.choices[Math.floor(rnd() * it.choices.length)].id])),
      });
      assert.equal(r.plan.ops[srcSide].length, 0, `round ${round}: wrote to source`);
      // mirror: take every non-ignore choice
      const m = await cycle(e, { direction, choose: (items) => Object.fromEntries(items.map((it) => [it.id, it.choices.find((c) => c.id !== 'ignore')?.id ?? 'ignore'])) });
      assert.equal(m.plan.ops[srcSide].length, 0);
      assert.deepEqual(m.after.items.map((i) => i.id), [], `round ${round} leftovers`);
      await assertInSync(e);
    }
  });
}
