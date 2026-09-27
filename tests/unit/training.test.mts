// اختبارات منطق منصة التدريب مقابل معادلات ملف التدريب في Google Sheets.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { currentWeek, effective, formatReps, normalizePlan, parseReps, parseRir, personalRecords, vlu, weeklyAverages, weeklySummary } from "../../src/lib/training.ts";

describe("منصة التدريب", () => {
  test("VLU = مجموع التكرارات × الوزن × (1 − RIR × 0.05)", () => {
    assert.equal(vlu([12, 12, 12], 50, 3), 36 * 50 * 0.85);
    assert.equal(vlu([10, 10, 10], 40, null), 1200);
    assert.equal(vlu([], 40, 2), 0);
  });
  test("قراءة التكرارات بصيغ المدربة", () => {
    assert.deepEqual(parseReps("3x12"), [12, 12, 12]);
    assert.deepEqual(parseReps("٣×١٠"), [10, 10, 10]);
    assert.deepEqual(parseReps("12-10-8"), [12, 10, 8]);
    assert.deepEqual(parseReps("12, 10، 8"), [12, 10, 8]);
    assert.deepEqual(parseReps(""), []);
    assert.equal(parseReps("abc"), null);
    assert.equal(parseReps("11x10"), null);
    assert.equal(formatReps([12, 12, 12]), "3×12");
    assert.equal(formatReps([12, 10, 8]), "12-10-8");
    assert.equal(parseRir(""), null); assert.equal(parseRir("2.5"), 2.5); assert.equal(parseRir("11"), undefined);
  });
  test("المسجّل الفارغ يأخذ المستهدف (مثل الشيت)", () => {
    const plan = { sets: 3, reps: [12, 12, 12], rir: 3 };
    const e = effective({ block_item_id: "a", week_no: 1, weight: 50, reps: [], rir: null }, plan);
    assert.deepEqual(e.reps, [12, 12, 12]); assert.equal(e.rir, 3); assert.equal(e.vlu, 1530);
  });
  test("الملخص الأسبوعي: الالتزام والتغيّر", () => {
    const plan = normalizePlan(Array(3).fill({ sets: 3, reps: [10, 10, 10], rir: 0 }), 3);
    const items = [{ id: "a", plan }, { id: "b", plan }];
    const logs = [
      { block_item_id: "a", week_no: 1, weight: 10, reps: [], rir: null },
      { block_item_id: "b", week_no: 1, weight: 10, reps: [], rir: null },
      { block_item_id: "a", week_no: 2, weight: 12, reps: [], rir: null },
    ];
    const s = weeklySummary(items, logs, 3);
    assert.equal(s[0].adherence, 1); assert.equal(s[0].vlu, 600);
    assert.equal(s[1].adherence, 0.5); assert.equal(s[1].vlu, 360); assert.equal(Math.round(s[1].change! * 100), -40);
    assert.equal(s[2].logged, 0); assert.equal(s[2].change, null);
  });
  test("الأسبوع الحالي", () => {
    assert.equal(currentWeek("2026-09-01", "2026-08-31", 5), 0);
    assert.equal(currentWeek("2026-09-01", "2026-09-01", 5), 1);
    assert.equal(currentWeek("2026-09-01", "2026-09-08", 5), 2);
    assert.equal(currentWeek("2026-09-01", "2026-12-01", 5), 5);
  });
  test("الأرقام القياسية ومتوسط الوزن الأسبوعي", () => {
    const pr = personalRecords([
      { exercise_id: "s", name: "Squat", weight: 60, logged_at: "2026-09-01" },
      { exercise_id: "s", name: "Squat", weight: 70, logged_at: "2026-09-08" },
      { exercise_id: "s", name: "Squat", weight: 65, logged_at: "2026-09-15" },
      { exercise_id: "b", name: "Bench", weight: 30, logged_at: "2026-09-02" },
    ]);
    assert.deepEqual(pr.map((p) => [p.name, p.best, p.previous, p.status]), [["Bench", 30, null, "first"], ["Squat", 70, 60, "new"]]);
    const avg = weeklyAverages([{ date: "2026-09-01", value: 80 }, { date: "2026-09-03", value: 79 }, { date: "2026-09-09", value: 78 }], "2026-09-01");
    assert.deepEqual(avg, [{ week: 1, avg: 79.5, n: 2 }, { week: 2, avg: 78, n: 1 }]);
  });
});
