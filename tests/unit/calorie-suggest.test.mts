// اختبارات السعرات المقترحة (calorie-suggest): التحويل من الاستبيان، الوزن الحالي، وقواعد الاقتراح.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { basis, currentWeight, explain, missingFor, profileFromIntake, suggestTargets, targetKcal, type CalorieProfile } from "../../src/lib/calorie-suggest.ts";

const base: CalorieProfile = { method: "tenhaaf", sex: "female", age: 30, height_cm: 165, body_fat: null, paf: 1.1, training_days: 4, minutes: 60, eb_factor: 0.8 };

describe("ملف الحساب من الاستبيان", () => {
  test("يحوّل إجابات الاستبيان لقيم الحاسبة", () => {
    const p = profileFromIntake({ gender: "أنثى", age: 30, days: "4 أيام", duration: "ساعة", steps: "3,000 – 6,000", goal: "نزول دهون" }, { height: 165, weight: 72 });
    assert.deepEqual(p, { method: "tenhaaf", sex: "female", age: 30, height_cm: 165, body_fat: null, paf: 1.1, training_days: 4, minutes: 60, eb_factor: 0.8 });
    const m = profileFromIntake({ gender: "ذكر", steps: "أكثر من 10,000", goal: "بناء عضل", duration: "ساعة ونص" }, {});
    assert.equal(m.sex, "male"); assert.equal(m.paf, 1.3); assert.equal(m.eb_factor, 1.05); assert.equal(m.minutes, 90);
    assert.deepEqual(missingFor(m), ["الطول", "العمر"]);
  });
});

describe("الوزن الحالي", () => {
  test("متوسط آخر 7 أيام من آخر تسجيل، وإلا وزن الاستبيان", () => {
    const logs = [{ logged_on: "2026-09-01", kg: 80 }, { logged_on: "2026-09-20", kg: 71 }, { logged_on: "2026-09-24", kg: 70 }, { logged_on: "2026-09-26", kg: 69.6 }];
    assert.deepEqual(currentWeight(logs, 75), { kg: 70.2, source: "logs" }); // (71 + 70 + 69.6) ÷ 3
    assert.deepEqual(currentWeight([], 75), { kg: 75, source: "intake" });
    assert.equal(currentWeight([], null), null);
  });
});

describe("السعرات المقترحة", () => {
  test("نفس حاسبة الموقع (Ten Haaf): مثال محسوب يدوياً", () => {
    // BMR = (49.94×70 + 2459.053×1.65 − 34.014×30 + 122.502) ÷ 4.184 = 1590.7
    // الراحة = 1590.7×1.1×1.2 = 2099.7 · التمرين = (1590.7×1.1 + 0.1×70×60)×1.2 = 2603.7
    // المحافظة = (2603.7×4 + 2099.7×3) ÷ 7 = 2387.7 · الهدف ×0.8 = 1910
    assert.equal(targetKcal(base, 70), 1910);
    assert.equal(targetKcal({ ...base, height_cm: null }, 70), null);
  });
  test("يقترح فقط عند فرق 50 سعرة أو أكثر، ويعدّل الكارب ليطابق", () => {
    const w = { kg: 70, source: "logs" as const };
    assert.equal(suggestTargets(base, w, { kcal: 1930, protein: 125, carbs: 200, fat: 62 }), null); // فرق 20
    const s = suggestTargets(base, w, { kcal: 2100, protein: 125, carbs: 250, fat: 62 })!;
    assert.equal(s.kcal, 1910); assert.equal(s.diff, -190);
    assert.equal(s.protein, 125); assert.equal(s.fat, 62);
    assert.equal(s.carbs, Math.round((1910 - 500 - 558) / 4)); // 213
    assert.equal(s.lowCarb, false);
    assert.match(explain(base, s), /متوسط آخر 7 أيام/);
  });
  test("لا يتكرر اقتراح تجاهلته المدربة، وبدون هدف حالي يقترح السعرات فقط", () => {
    const w = { kg: 70, source: "logs" as const };
    assert.equal(suggestTargets({ ...base, dismissed_kcal: 1910 }, w, { kcal: 2100, protein: 125, carbs: 250, fat: 62 }), null);
    const s = suggestTargets(base, w, null)!;
    assert.equal(s.kcal, 1910); assert.equal(s.diff, null); assert.equal(s.carbs, null);
  });
  test("تنبيه الكارب المنخفض", () => {
    const s = suggestTargets(base, { kg: 70, source: "logs" }, { kcal: 2500, protein: 250, carbs: 200, fat: 110 })!; // 1910 − 1000 − 990 < 0
    assert.equal(s.carbs, 0); assert.equal(s.lowCarb, true);
  });
});

describe("basis — أساس الحسبة للتأكد", () => {
  test("يعرض المعادلة والوزن والطول والعمر والنشاط والتمرين والهدف", () => {
    const p = profileFromIntake({ gender: "أنثى", age: 30, days: "4 أيام", duration: "ساعة", steps: "3,000 – 6,000", goal: "نزول دهون" }, { weight: 74, height: 165 });
    const b = basis(p, { kg: 74, source: "intake" }).join(" | ");
    for (const t of ["Ten Haaf", "74 كغ (من الاستبيان)", "165 سم", "العمر: 30", "أنثى", "4 أيام × 60 دقيقة"]) assert.ok(b.includes(t), t);
  });
});
