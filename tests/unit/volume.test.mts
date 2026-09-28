import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { muscleLabel, muscleOrder, volumeStatus, weeklyVolume } from "../../src/lib/volume.ts";

const w = (...sets: number[]) => sets.map((s) => ({ sets: s, reps: [], rir: null }));

describe("الجولات الأسبوعية لكل عضلة", () => {
  test("الأساسية جولة كاملة، والثانوية نصف جولة، لكل أسبوع", () => {
    const v = weeklyVolume([
      { primary_muscle: "Chest / الصدر", secondary_muscles: ["Triceps / الترايسبس", "Shoulders / الأكتاف"], plan: w(3, 4) },
      { primary_muscle: "Triceps / الترايسبس", secondary_muscles: [], plan: w(3, 3) },
      { primary_muscle: "Stretching / الإطالات", secondary_muscles: ["Chest / الصدر"], plan: w(2, 2) },
      { primary_muscle: "Chest / الصدر", secondary_muscles: ["Chest / الصدر"], plan: w(0, 2) },
    ], 2);
    assert.deepEqual(Object.fromEntries(v[0]), { "Chest / الصدر": 3, "Triceps / الترايسبس": 4.5, "Shoulders / الأكتاف": 1.5 });
    assert.deepEqual(Object.fromEntries(v[1]), { "Chest / الصدر": 6, "Triceps / الترايسبس": 5, "Shoulders / الأكتاف": 2 });
  });
  test("الترتيب والحالة والحدود", () => {
    const v = [new Map([["A", 4], ["B", 10]])];
    assert.deepEqual(muscleOrder(v, { C: { min: 6 } }), ["B", "A", "C"]);
    assert.equal(volumeStatus(8, { min: 10, max: 20 }), "low");
    assert.equal(volumeStatus(22, { min: 10, max: 20 }), "high");
    assert.equal(volumeStatus(10, { min: 10, max: 20 }), "ok");
    assert.equal(volumeStatus(10, undefined), "none");
    assert.equal(muscleLabel("Chest / الصدر"), "الصدر");
  });
});
