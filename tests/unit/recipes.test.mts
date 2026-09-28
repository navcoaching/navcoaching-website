// قوالب كتيب الوصفات: كل قالب فطور + غداء + عشاء + سناك، من وصفات مختلفة، بأرقام الكتيب حرفياً وضمن حدود قاعدة البيانات.
import { test } from "node:test";
import assert from "node:assert/strict";
// @ts-expect-error سكربت JS
import { buildPlans, loadRecipes, kcalOf, recipeTemplatesSql } from "../../scripts/recipes-sql.mjs";

type R = { id: string; slot: string; protein: number; carbs: number; fat: number; ingredients: string[]; steps: string[] };

test("26 وصفة: 9 فطور، 9 غداء وعشاء، 8 سناك، بأرقام ضمن حدود الجدول", () => {
  const rs = loadRecipes() as R[];
  assert.equal(rs.length, 26);
  assert.deepEqual(["b", "l", "s"].map((s) => rs.filter((r) => r.slot === s).length), [9, 9, 8]);
  for (const r of rs) {
    assert.ok(r.protein >= 0 && r.protein <= 500 && r.carbs >= 0 && r.carbs <= 500 && r.fat >= 0 && r.fat <= 300, r.id);
    assert.ok(r.ingredients.length > 0 && r.steps.length > 0, r.id);
  }
  assert.equal(new Set(rs.map((r) => r.id)).size, 26);
});

test("كل قالب: فطور وغداء وعشاء وسناك بوصفات مختلفة، والمجاميع صحيحة", () => {
  const plans = buildPlans();
  assert.equal(plans.length, 5);
  for (const p of plans) {
    assert.deepEqual(p.meals.map((m: { kind: string }) => m.kind), ["breakfast", "lunch", "dinner", "snack"], p.name);
    assert.equal(new Set(p.meals.map((m: { title: string }) => m.title)).size, 4, p.name);
    const sum = p.meals.flatMap((m: { items: { protein: number; carbs: number; fat: number }[] }) => m.items).reduce((a: number, i: { protein: number; carbs: number; fat: number }) => a + kcalOf(i), 0);
    assert.equal(Math.round(sum), p.kcal, p.name);
  }
});

test("القوالب تختلف بحسب هدفها (أعلى/أقل سعرات، بروتين، كارب)", () => {
  const by = Object.fromEntries(buildPlans().map((p: { name: string }) => [p.name, p])) as Record<string, { kcal: number; protein: number; carbs: number }>;
  const all = Object.values(by);
  assert.equal(by["قالب منخفض السعرات"].kcal, Math.min(...all.map((p) => p.kcal)));
  assert.equal(by["قالب عالي السعرات"].kcal, Math.max(...all.map((p) => p.kcal)));
  assert.equal(by["قالب عالي البروتين"].protein, Math.max(...all.map((p) => p.protein)));
  assert.equal(by["قالب عالي الكارب"].carbs, Math.max(...all.map((p) => p.carbs)));
  assert.equal(by["قالب قليل الكارب"].carbs, Math.min(...all.map((p) => p.carbs)));
});

test("SQL يرفض إعادة التشغيل ولا يحتوي فاصل dollar-quote داخلياً", () => {
  const sql = recipeTemplatesSql() as string;
  assert.match(sql, /مطبّق من قبل/);
  assert.equal(sql.split("$rt$").length - 1, 2);
});
