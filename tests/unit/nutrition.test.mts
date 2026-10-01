// اختبارات منطق التغذية مقابل أرقام أوراق «تغذية ١–٥» و«التعليمات».
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { kcalOf, remaining, sumMacros, targetCheck } from "../../src/lib/nutrition.ts";
import { plansNear } from "../../src/lib/nutrition.ts";

test("السعرات = بروتين×4 + كارب×4 + دهون×9 (فطور الجدول 1)", () => {
  const breakfast = [{ protein: 12.6, carbs: 0.7, fat: 9.5 }, { protein: 6.6, carbs: 28.6, fat: 2.6 }, { protein: 5.5, carbs: 0, fat: 5.5 }];
  const t = sumMacros(breakfast);
  assert.deepEqual([t.protein, t.carbs, t.fat], [24.7, 29.3, 17.6]);
  assert.equal(Math.round(t.kcal * 10) / 10, 374.4);
  assert.equal(kcalOf({ protein: 30, carbs: 0, fat: 5.4 }), 168.6);
});
test("المتبقي من الهدف (موجب متبقٍ، سالب تجاوز)", () => {
  const r = remaining({ kcal: 1885, protein: 125, carbs: 200, fat: 62 }, { kcal: 1748.5, protein: 118.2, carbs: 169.3, fat: 66.5 });
  assert.equal(r.kcal.left, 136.5); assert.equal(r.protein.left, 6.8); assert.equal(r.fat.left, -4.5);
  assert.equal(remaining({ kcal: null, protein: 100, carbs: null, fat: null }, sumMacros([])).kcal.left, null);
});
test("تطابق السعرات مع الماكروز (ورقة التعليمات: 1885 مقابل 1858)", () => {
  assert.deepEqual(targetCheck({ kcal: 1885, protein: 125, carbs: 200, fat: 62 }), { fromMacros: 1858, diff: 27, ok: true });
  assert.equal(targetCheck({ kcal: 2500, protein: 125, carbs: 200, fat: 62 })!.ok, false);
  assert.equal(targetCheck({ kcal: null, protein: 1, carbs: 1, fat: 1 }), null);
});

describe("plansNear — قوالب قريبة من هدف السعرات", () => {
  const P = (id: string, kcal: number) => ({ id, total: { kcal } });
  test("فرق 200 أو أقل، الأقرب أولاً، و«قريب جداً» حتى 100", () => {
    const r = plansNear([P("a", 2300), P("b", 1850), P("c", 2150), P("d", 2201), P("e", 0)], 2000);
    assert.deepEqual(r.map((p) => [p.id, p.diff, p.close]), [["b", -150, false], ["c", 150, false]]);
    const r2 = plansNear([P("x", 2100), P("y", 1901), P("z", 2200)], 2000);
    assert.deepEqual(r2.map((p) => [p.id, p.close]), [["y", true], ["x", true], ["z", false]]);
  });
  test("بدون هدف سعرات لا اقتراحات", () => {
    assert.deepEqual(plansNear([P("a", 2000)], null), []);
  });
});
