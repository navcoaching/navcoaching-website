import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { HEADER, SHARED } from "../scripts/sync-shared.mjs";
import { calculateIntake, validateIntake } from "../src/shared/calories.ts";

test("shared logic matches the website copy", () => {
  for (const [from, to] of SHARED) {
    const site = readFileSync(new URL(from, new URL("../scripts/", import.meta.url)), "utf8");
    const app = readFileSync(new URL(to, new URL("../scripts/", import.meta.url)), "utf8");
    assert.equal(app, HEADER + site, `${to} قديم: شغّل node scripts/sync-shared.mjs`);
  }
});

test("calculator works in the app", () => {
  const i = { method: "cunningham" as const, weight: 70, bodyFat: 20, heightCm: NaN, age: NaN, sex: null, paf: 1, minutes: 60, trainingDays: 4, ebFactor: 0.8 };
  assert.deepEqual(validateIntake(i), {});
  const r = calculateIntake(i as never);
  assert.ok(r.target > 1000 && r.target < r.maintenance);
});
