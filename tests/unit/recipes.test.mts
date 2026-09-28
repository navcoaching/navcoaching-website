// قوالب كتيب الوصفات: كل قالب فطور + غداء + عشاء + سناك، من وصفات مختلفة، بأرقام الكتيب حرفياً وضمن حدود قاعدة البيانات.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
// @ts-expect-error سكربت JS
import { buildPlans, loadRecipes, kcalOf, recipeTemplatesSql } from "../../scripts/recipes-sql.mjs";

type R = { id: string; slot: string; set?: string; protein: number; carbs: number; fat: number; kcal_book: number; basis?: { food: string; g: number }[]; ingredients: string[]; steps: string[] };

test("26 وصفة من الكتيب (9 فطور، 9 غداء وعشاء، 8 سناك) + 9 وصفات مضادات أكسدة، بأرقام ضمن حدود الجدول", () => {
  const rs = loadRecipes() as R[];
  assert.equal(rs.length, 35);
  const book = rs.filter((r) => !r.set), ao = rs.filter((r) => r.set === "antioxidant");
  assert.deepEqual(["b", "l", "s"].map((s) => book.filter((r) => r.slot === s).length), [9, 9, 8]);
  assert.deepEqual(["b", "l", "s"].map((s) => ao.filter((r) => r.slot === s).length), [3, 3, 3]);
  for (const r of rs) {
    assert.ok(r.protein >= 0 && r.protein <= 500 && r.carbs >= 0 && r.carbs <= 500 && r.fat >= 0 && r.fat <= 300, r.id);
    assert.ok(r.ingredients.length > 0 && r.steps.length > 0, r.id);
  }
  assert.equal(new Set(rs.map((r) => r.id)).size, 35);
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

test("وصفات مضادات الأكسدة: الأرقام = مجموع مكوناتها من قاعدة الأكل (USDA) والسعرات = بروتين×4 + كارب×4 + دهون×9", () => {
  const foods = JSON.parse(readFileSync(new URL("../../db/seed/foods.json", import.meta.url), "utf8")) as Record<string, number | string>[];
  const byName = new Map(foods.map((f) => [f.name_ar as string, f]));
  const ao = (loadRecipes() as R[]).filter((r) => r.set === "antioxidant");
  for (const r of ao) {
    assert.ok(r.basis && r.basis.length > 0, r.id);
    const t = { p: 0, c: 0, f: 0 };
    for (const b of r.basis!) {
      const f = byName.get(b.food);
      assert.ok(f, `${r.id}: ${b.food} غير موجود بقاعدة الأكل`);
      t.p += (Number(f!.protein_100) * b.g) / 100; t.c += (Number(f!.carbs_100) * b.g) / 100; t.f += (Number(f!.fat_100) * b.g) / 100;
    }
    assert.ok(Math.abs(t.p - r.protein) <= 0.06 && Math.abs(t.c - r.carbs) <= 0.06 && Math.abs(t.f - r.fat) <= 0.06, r.id);
    assert.equal(r.kcal_book, Math.round(4 * r.protein + 4 * r.carbs + 9 * r.fat), r.id);
  }
});

test("قالب مضادات الأكسدة: فطور وغداء وعشاء وسناك، كلها من وصفات مضادات الأكسدة", () => {
  const [p] = buildPlans(loadRecipes(), "antioxidant");
  assert.equal(p.name, "قالب مضادات الأكسدة");
  assert.deepEqual(p.meals.map((m: { kind: string }) => m.kind), ["breakfast", "lunch", "dinner", "snack"]);
  const names = new Set((loadRecipes() as (R & { name: string })[]).filter((r) => r.set === "antioxidant").map((r) => r.name));
  for (const m of p.meals) assert.ok(names.has(m.title), m.title);
  assert.equal(buildPlans().length, 5); // القوالب الخمسة ما تتأثر بالوصفات الجديدة
});
