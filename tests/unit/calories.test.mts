// اختبارات حاسبة توازن الطاقة مقابل مثال ملف Henselmans Energy Balance Calculator نفسه.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { calculateEnergyBalance, validate, daysBetween, type EnergyInput } from "../../src/lib/calories.ts";

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
