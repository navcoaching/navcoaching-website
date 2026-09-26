// اختبارات منطق حاسبة السعرات (قيم محسوبة يدوياً).
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { calculateCalories, validate, activityFactor, type CalorieInput } from "../../src/lib/calories.ts";

const base: CalorieInput = { sex: "male", age: 30, weight: 80, height: 180, bodyFat: 20, steps: 8000, goal: "lose", level: "beginner", protein: "moderate" };
const near = (a: number, b: number, eps = 0.01) => assert.ok(Math.abs(a - b) < eps, `${a} ≠ ${b}`);

describe("حاسبة السعرات", () => {
  test("مع نسبة الدهون: Katch-McArdle والكتلة الخالية", () => {
    const r = calculateCalories(base);
    near(r.lbm, 64);                       // 80 × 0.8
    near(r.bmr, 370 + 21.6 * 64);          // 1752.4
    assert.equal(r.formula, "katch");
    assert.equal(r.activity, 1.5);         // 8000 خطوة
    near(r.tdee, 1752.4 * 1.5);            // 2628.6
    near(r.target, 2628.6 - 400);          // 2228.6
    near(r.proteinG, 1.6 * 64);            // 102.4
    near(r.fatG, (2228.6 * 0.27) / 9);     // 66.858
    near(r.carbsG, (2228.6 - 102.4 * 4 - 66.858 * 9) / 4);
    assert.equal(r.lbmEstimated, false);
  });
  test("بدون نسبة الدهون: Mifflin-St Jeor وتنبيه الدقة", () => {
    const m = calculateCalories({ ...base, bodyFat: null });
    near(m.bmr, 10 * 80 + 6.25 * 180 - 5 * 30 + 5); // 1780
    assert.equal(m.formula, "mifflin");
    assert.equal(m.lbmEstimated, true);
    near(m.lbm, 80);
    assert.ok(m.warnings.some((w) => w.includes("أقل دقة")));
    const f = calculateCalories({ ...base, sex: "female", bodyFat: null });
    near(f.bmr, 10 * 80 + 6.25 * 180 - 5 * 30 - 161);
  });
  test("عوامل النشاط حسب الخطوات", () => {
    assert.deepEqual([0, 4999, 5000, 7499, 7500, 9999, 10000, 12499, 12500, 30000].map(activityFactor),
      [1.2, 1.2, 1.35, 1.35, 1.5, 1.5, 1.65, 1.65, 1.8, 1.8]);
  });
  test("الهدف والبروتين حسب المستوى", () => {
    const tdee = calculateCalories(base).tdee;
    near(calculateCalories({ ...base, goal: "gain" }).target, tdee + 400);
    near(calculateCalories({ ...base, goal: "maintain" }).target, tdee);
    near(calculateCalories({ ...base, level: "advanced" }).proteinPerKg, 2.0);
    near(calculateCalories({ ...base, protein: "high" }).proteinPerKg, 2.4);
    near(calculateCalories({ ...base, protein: "high", level: "advanced" }).proteinPerKg, 2.8);
  });
  test("الكربوهيدرات لا تكون سالبة، مع تنبيه", () => {
    const r = calculateCalories({ sex: "female", age: 90, weight: 45, height: 150, bodyFat: null, steps: 0, goal: "lose", level: "advanced", protein: "high" });
    assert.equal(r.carbsG, 0);
    assert.ok(r.warnings.some((w) => w.includes("ما بقي شيء للكربوهيدرات")));
    assert.ok(r.warnings.some((w) => w.includes("أقل من الحد الأدنى")));
  });
  test("التحقق من المدخلات", () => {
    assert.deepEqual(validate(base), {});
    const e = validate({ ...base, weight: 0, height: -5, age: 0, sex: undefined, bodyFat: 80 });
    assert.match(e.weight!, /أكبر من صفر/);
    assert.match(e.height!, /أكبر من صفر/);
    assert.match(e.age!, /أكبر من صفر/);
    assert.ok(e.sex && e.bodyFat);
    assert.equal(validate({ ...base, bodyFat: null }).bodyFat, undefined); // اختيارية
    assert.ok(validate({ ...base, age: 25.5 }).age);
    assert.equal(validate({ ...base, steps: 0 }).steps, undefined);
  });
});
