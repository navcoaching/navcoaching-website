import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { SHOULDER_HEADS, muscleLabel, muscleOrder, volumeStatus, weeklyVolume } from "../../src/lib/volume.ts";

const w = (...sets: number[]) => sets.map((s) => ({ sets: s, reps: [], rir: null }));

describe("الجولات الأسبوعية لكل عضلة", () => {
  test("الأساسية جولة كاملة، والثانوية نصف جولة، لكل أسبوع", () => {
    const v = weeklyVolume([
      { primary_muscle: "Chest / الصدر", secondary_muscles: ["Triceps / الترايسبس", "Shoulders / الأكتاف"], plan: w(3, 4) },
      { primary_muscle: "Triceps / الترايسبس", secondary_muscles: [], plan: w(3, 3) },
      { primary_muscle: "Stretching / الإطالات", secondary_muscles: ["Chest / الصدر"], plan: w(2, 2) },
      { primary_muscle: "Chest / الصدر", secondary_muscles: ["Chest / الصدر"], plan: w(0, 2) },
    ], 2);
    assert.deepEqual(Object.fromEntries(v[0]), { "Chest / الصدر": 3, "Triceps / الترايسبس": 4.5 });
    assert.deepEqual(Object.fromEntries(v[1]), { "Chest / الصدر": 6, "Triceps / الترايسبس": 5 });
  });
  test("الأكتاف: ثلاثة رؤوس من تمارين الأكتاف فقط، والثانوية لا تُحسب", () => {
    const sh = "Shoulders / الأكتاف";
    const v = weeklyVolume([
      { name: "DB Lateral Raise", primary_muscle: sh, pattern: "Shoulder Lateral Raise / رفع جانبي للكتف", plan: w(4) },
      { name: "DB Shoulder Press", primary_muscle: sh, pattern: "Vertical Push / دفع عمودي", plan: w(3) },
      { name: "Cable Reardelt Fly", primary_muscle: sh, pattern: "Shoulder Rear Pull / سحب خلفي للكتف", plan: w(2) },
      { name: "Bench", primary_muscle: "Chest / الصدر", secondary_muscles: [sh], plan: w(5) },
    ], 1);
    assert.deepEqual(Object.fromEntries(v[0]), { [SHOULDER_HEADS.side]: 4, [SHOULDER_HEADS.front]: 3, [SHOULDER_HEADS.rear]: 2, "Chest / الصدر": 5 });
  });
  test("الترتيب والحالة والحدود", () => {
    const v = [new Map([["A", 4], ["B", 10]])];
    assert.deepEqual(muscleOrder(v, { C: { min: 6 } }), ["B", "A", "C"]);
    assert.equal(volumeStatus(8, { min: 10, max: 20 }), "low");
    assert.equal(volumeStatus(22, { min: 10, max: 20 }), "high");
    assert.equal(volumeStatus(10, { min: 10, max: 20 }), "ok");
    assert.equal(volumeStatus(10, undefined), "none");
    assert.equal(muscleLabel("Chest / الصدر"), "Chest");
  });
});
