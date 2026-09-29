// قوالب كتيب الوصفات: كل قالب فطور + غداء + عشاء + سناك، من وصفات مختلفة، بأرقام الكتيب حرفياً وضمن حدود قاعدة البيانات.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
// @ts-expect-error سكربت JS
import { buildPlans, loadRecipes, kcalOf, recipeTemplatesSql } from "../../scripts/recipes-sql.mjs";

type R = { id: string; slot: string; set?: string; original?: { kcal: number }; protein: number; carbs: number; fat: number; kcal_book: number; basis?: { food: string; g: number }[]; ingredients: string[]; steps: string[] };

test("26 وصفة من الكتيب (9 فطور، 9 غداء وعشاء، 8 سناك) + 9 مضادات أكسدة + 17 وصفة إضافية، بأرقام ضمن حدود الجدول", () => {
  const rs = loadRecipes() as R[];
  assert.equal(rs.length, 60);
  const book = rs.filter((r) => !r.set), ao = rs.filter((r) => r.set === "antioxidant"), ex = rs.filter((r) => r.set === "extra");
  assert.deepEqual(["b", "l", "s"].map((s) => ex.filter((r) => r.slot === s).length), [4, 9, 4]);
  assert.deepEqual(["b", "l", "s"].map((s) => book.filter((r) => r.slot === s).length), [9, 9, 8]);
  assert.deepEqual(["b", "l", "s"].map((s) => ao.filter((r) => r.slot === s).length), [3, 3, 3]);
  for (const r of rs) {
    assert.ok(r.protein >= 0 && r.protein <= 500 && r.carbs >= 0 && r.carbs <= 500 && r.fat >= 0 && r.fat <= 300, r.id);
    assert.ok(r.ingredients.length > 0 && r.steps.length > 0, r.id);
  }
  assert.equal(new Set(rs.map((r) => r.id)).size, 60);
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

test("SQL يحدّث القالب الموجود بدل التكرار، ولا يحتوي فاصل dollar-quote داخلياً", () => {
  const sql = recipeTemplatesSql() as string;
  assert.match(sql, /DELETE FROM plan_meals WHERE plan_id = v_plan/);
  assert.equal(sql.split("$rt$").length - 1, 2);
});

test("كل وصفة لها مكونات محسوبة (مضادات الأكسدة، الإضافية، والوصفات المصحّحة): الأرقام = مجموع المكونات من قاعدة الأكل (USDA) والسعرات = بروتين×4 + كارب×4 + دهون×9", () => {
  const foods = JSON.parse(readFileSync(new URL("../../db/seed/foods.json", import.meta.url), "utf8")) as Record<string, number | string>[];
  const byName = new Map(foods.map((f) => [f.name_ar as string, f]));
  // سكوب الواي من ملف تغذية المدربة: 25غ بروتين، 3 كارب، 2 دهون لكل سكوب (30غ)
  byName.set("سكوب واي بروتين (ملف المدربة)", { protein_100: 2500 / 30, carbs_100: 300 / 30, fat_100: 200 / 30 });
  const ao = (loadRecipes() as R[]).filter((r) => r.basis);
  assert.equal(ao.length, 9 + 17 + 10 + 8);
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

test("الوصفات العشر المصحّحة: سعرات الكتيب = من الماكروز، والقيم الأصلية محفوظة", () => {
  const fixed = (loadRecipes() as R[]).filter((r) => r.original);
  assert.equal(fixed.length, 10);
  for (const r of fixed) assert.equal(r.kcal_book, Math.round(4 * r.protein + 4 * r.carbs + 9 * r.fat), r.id);
});

test("وصفات الألياف: كل وجبة رئيسية 8غ ألياف أو أكثر والسناك 5.6غ (20% من 28غ)، والألياف = مجموع المكونات", () => {
  const foods = JSON.parse(readFileSync(new URL("../../db/seed/foods.json", import.meta.url), "utf8")) as { name_ar: string; fiber_100: number }[];
  const fib = new Map(foods.map((f) => [f.name_ar, f.fiber_100]));
  const fr = (loadRecipes() as (R & { fiber: number })[]).filter((r) => r.set === "fiber");
  assert.equal(fr.length, 8);
  for (const r of fr) {
    assert.ok(r.fiber >= (r.slot === "s" ? 5.6 : 8), r.id);
    const sum = r.basis!.reduce((a, b) => a + ((fib.get(b.food) ?? 0) * b.g) / 100, 0);
    assert.ok(Math.abs(sum - r.fiber) <= 0.06, r.id);
  }
  const [p] = buildPlans(loadRecipes(), "fiber");
  assert.equal(p.name, "قالب عالي الألياف");
  assert.deepEqual(p.meals.map((m: { kind: string }) => m.kind), ["breakfast", "lunch", "dinner", "snack"]);
  assert.ok(p.fiber >= 28, String(p.fiber));
  assert.match(p.notes, /ألياف \d+غ/);
});

test("مكتبة الوجبات: كل الوصفات (60) كوجبات، وSQL المكتبة يضع is_library ولا يمس القوالب الخمسة", () => {
  const [lib] = buildPlans(loadRecipes(), "library");
  assert.equal(lib.name, "مكتبة الوجبات");
  assert.equal(lib.meals.length, 60);
  assert.equal(new Set(lib.meals.map((m: { title: string }) => m.title)).size, 60);
  assert.ok(lib.meals.every((m: { kind: string; items: unknown[] }) => ["breakfast", "lunch", "snack"].includes(m.kind) && m.items.length === 1));
  assert.match(recipeTemplatesSql("library") as string, /is_library/);
  assert.doesNotMatch(recipeTemplatesSql("main") as string, /is_library/); // الملف الرئيسي يعمل قبل migration 030
  assert.equal(buildPlans().length, 5);
});
