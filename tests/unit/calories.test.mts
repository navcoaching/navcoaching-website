// اختبارات حاسبة توازن الطاقة مقابل مثال ملف Henselmans Energy Balance Calculator نفسه.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { calculateEnergyBalance, validate, daysBetween, macrosFor, proteinPerKg, validateMacroSettings, MACRO_DEFAULTS, type EnergyInput } from "../../src/lib/calories.ts";

// المثال الموجود في ملف الإكسل
const sheet: EnergyInput = { leanChange: 5, fatChange: -3, startDate: "2019-12-10", endDate: "2020-01-10", trainingKcal: 2069, trainingDays: 6, restKcal: 1548 };
const near = (a: number, b: number, eps = 0.5) => assert.ok(Math.abs(a - b) < eps, `${a} ≠ ${b}`);

describe("حاسبة توازن الطاقة", () => {
  test("تطابق مخرجات ملف الإكسل", () => {
    const r = calculateEnergyBalance(sheet);
    near(r.leanMJ, 38, 1e-9);
    near(r.fatMJ, -118.5, 1e-9);
    assert.equal(r.days, 31);
    near(r.avgIntake, 1994.571429, 1e-5);
    assert.equal(Math.round(r.netKcal), -19227);       // Net energy balance (kcal)
    assert.equal(Math.round(r.dailyBalance), -620);    // Daily energy balance (kcal)
    assert.equal(Math.round(r.dailyBalancePct * 100), -24); // Daily energy balance (%)
    near(r.maintenance, 1994.571429 + 620.23, 0.1);
  });
  test("فائض عند زيادة الدهون والعضل", () => {
    const r = calculateEnergyBalance({ ...sheet, leanChange: 1, fatChange: 0.5 });
    assert.ok(r.dailyBalance > 0);
    assert.ok(r.maintenance < r.avgIntake);
  });
  test("أيام الراحة = 7 − أيام التمرين", () => {
    near(calculateEnergyBalance({ ...sheet, trainingDays: 0 }).avgIntake, 1548, 1e-9);
    near(calculateEnergyBalance({ ...sheet, trainingDays: 7 }).avgIntake, 2069, 1e-9);
  });
  test("تنبيه المدة القصيرة", () => {
    const r = calculateEnergyBalance({ ...sheet, endDate: "2019-12-17" });
    assert.ok(r.warnings.some((w) => w.includes("أقل من أسبوعين")));
  });
  test("التحقق من المدخلات", () => {
    assert.deepEqual(validate(sheet), {});
    assert.equal(daysBetween("2020-02-28", "2020-03-01"), 2);
    const e = validate({ ...sheet, trainingKcal: 0, restKcal: -5, fatChange: NaN, endDate: "2019-12-01", trainingDays: 8 });
    assert.match(e.trainingKcal!, /أكبر من صفر/);
    assert.match(e.restKcal!, /أكبر من صفر/);
    assert.ok(e.fatChange && e.trainingDays);
    assert.match(e.endDate!, /بعد الأول/);
  });
});

import { calculateIntake, validateIntake } from "../../src/lib/calories.ts";
describe("حاسبة السعرات اليومية (Henselmans Energy Intake Calculator)", () => {
  const common = { paf: 1.0, minutes: 60, trainingDays: 4, ebFactor: 0.8 };
  const r0 = (v: number) => Math.round(v);
  test("Cunningham: مطابق لمثال الملف", () => {
    const r = calculateIntake({ ...common, method: "cunningham", weight: 80, bodyFat: 15 });
    assert.equal(r.ffm, 68);
    assert.deepEqual([r0(r.bmr), r0(r.trainingEE), r0(r.restDayEE), r0(r.trainingDayEE), r0(r.maintenance), r0(r.target)], [1839, 480, 2207, 2783, 2536, 2029]);
  });
  test("Tinsley: مطابق لمثال الملف", () => {
    const r = calculateIntake({ ...common, method: "tinsley", weight: 90 });
    assert.deepEqual([r0(r.bmr), r0(r.trainingEE), r0(r.restDayEE), r0(r.trainingDayEE), r0(r.maintenance), r0(r.target)], [2242, 540, 2690, 3338, 3061, 2449]);
  });
  test("Ten Haaf: مطابق لمثال الملف", () => {
    const r = calculateIntake({ ...common, method: "tenhaaf", weight: 85, heightCm: 178, age: 35, sex: "male" });
    assert.deepEqual([Math.floor(r.bmr), r0(r.trainingEE), r0(r.restDayEE), r0(r.trainingDayEE), r0(r.maintenance), r0(r.target)], [1996, 510, 2396, 3008, 2745, 2196]);
  });
  test("التحقق حسب الطريقة", () => {
    assert.ok(validateIntake({ ...common, method: "cunningham", weight: 80 }).bodyFat);
    const e = validateIntake({ ...common, method: "tenhaaf", weight: 0 });
    assert.ok(e.weight && e.heightCm && e.age && e.sex);
    assert.deepEqual(validateIntake({ ...common, method: "tinsley", weight: 90 }), {});
  });
});

describe("الماكروز من السعرات", () => {
  test("البروتين: معتدل 1.6 غ/كغ، عالي 2.2 غ/كغ (الافتراضي معتدل)", () => {
    assert.equal(proteinPerKg("moderate"), 1.6); assert.equal(proteinPerKg("high"), 2.2);
    const m = macrosFor(2029, 80);
    assert.deepEqual([m.protein, m.fat, m.carbs], [128, 64, 235]); // (2029 − 512 − 576) ÷ 4 = 235.25
    const h = macrosFor(2029, 80, { proteinPerKg: 2.2, fatPerKg: 0.8 });
    assert.deepEqual([h.protein, h.fat, h.carbs], [176, 64, 187]); // (2029 − 704 − 576) ÷ 4 = 187.25
  });
  test("الكارب لا ينزل عن صفر مع تنبيه", () => {
    const low = macrosFor(1200, 90, { proteinPerKg: 2.2, fatPerKg: 0.8 });
    assert.equal(low.carbs, 0); assert.equal(low.lowCarb, true); assert.ok(low.carbsRaw < 0);
  });
  test("التحقق من حدود الدهون", () => {
    assert.deepEqual(validateMacroSettings({ fatPerKg: MACRO_DEFAULTS.fatPerKg }), {});
    assert.ok(validateMacroSettings({ fatPerKg: 5 }).fatPerKg);
    assert.ok(validateMacroSettings({ fatPerKg: NaN }).fatPerKg);
  });
});
