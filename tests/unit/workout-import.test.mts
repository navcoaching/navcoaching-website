// تعبئة التسجيل من صورة Strong: التطبيع، المطابقة، وتحويل المجموعات.
import { test } from "node:test";
import assert from "node:assert/strict";
import { matchExercises, normalizeName, toLog } from "../../src/lib/workout-import.ts";

const day = [
  { id: "i1", exercise_id: "e1", name: "Mid Leg Press" },
  { id: "i2", exercise_id: "e2", name: "Hip Thrusts" },
  { id: "i3", exercise_id: "e3", name: "Lying Leg Curl" },
];

test("التطبيع: الأقواس والجمع والرموز", () => {
  assert.equal(normalizeName("Hip Thrust (Barbell)"), "hip thrust");
  assert.equal(normalizeName("Hip Thrusts"), "hip thrust");
  assert.equal(normalizeName("  Lying Leg-Curl (Machine) "), "lying leg curl");
  assert.equal(normalizeName("Cross"), "cross");
});

test("تحويل المجموعات: تجاهل الإحماء، أثقل وزن، الباوند، وRPE", () => {
  assert.deepEqual(toLog({ name: "x", unit: "kg", sets: [
    { weight: 40, reps: 10, warmup: true }, { weight: 80, reps: 10 }, { weight: 85, reps: 8, rpe: 8.5 }] }),
    { weight: 85, weights: [80, 85], reps: [10, 8], rir: 2 });
  assert.deepEqual(toLog({ name: "x", unit: "lb", sets: [{ weight: 100, reps: 12 }] }), { weight: 45.5, weights: [45.5], reps: [12], rir: null });
  assert.equal(toLog({ name: "x", unit: "kg", sets: [{ weight: 20, reps: 10, warmup: true }] }), null);
});

test("المطابقة: الربط المحفوظ، ثم الاسم، ثم التشابه، وغير المطابق للمتدرب", () => {
  const rows = matchExercises([
    { name: "Hip Thrust (Barbell)", unit: "kg", sets: [{ weight: 60, reps: 10 }] },
    { name: "Leg Press (Machine)", unit: "kg", sets: [{ weight: 100, reps: 12 }] },
    { name: "Seated Leg Curl (Machine)", unit: "kg", sets: [{ weight: 30, reps: 12 }] },
    { name: "Plank", unit: null, sets: [{ weight: null, reps: 1 }] },
  ], day, new Map([["seated leg curl", "e3"]]));
  assert.deepEqual(rows.map((r) => [r.itemId, r.how]), [["i2", "name"], ["i1", "partial"], ["i3", "alias"], [null, null]]);
  assert.equal(rows[0].log!.weight, 60);
});

test("كل تمرين في اليوم يُستخدم مرة واحدة", () => {
  const rows = matchExercises([
    { name: "Hip Thrusts", unit: "kg", sets: [{ weight: 60, reps: 10 }] },
    { name: "Hip Thrust (Barbell)", unit: "kg", sets: [{ weight: 70, reps: 8 }] },
  ], day, new Map());
  assert.deepEqual(rows.map((r) => r.itemId), ["i2", null]);
});
