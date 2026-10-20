// تصنيف مصادر الأكل: نسب الاحتياج اليومي لكل حصة وعتبات «غني بـ / مصدر جيد» (FDA)، على بيانات USDA في foods.json.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { SOURCE_TYPES, foodTags, matchesTag, nutrientRows, type FoodDetail } from "../../src/lib/food-tags.ts";

const foods = JSON.parse(readFileSync(new URL("../../db/seed/foods.json", import.meta.url), "utf8")) as (FoodDetail & { kcal_100: number })[];
const byName = (n: string) => foods.find((f) => f.name_ar === n)!;

test("كل صنف له نوع مصدر من القائمة، وألياف، ومعادن/فيتامينات من USDA", () => {
  for (const f of foods) {
    assert.ok((SOURCE_TYPES as readonly string[]).includes(f.source_type!), f.name_ar);
    assert.equal(typeof f.fiber_100, "number", f.name_ar);
    assert.ok(f.micros && Object.keys(f.micros).length >= 5, f.name_ar);
  }
  assert.equal(byName("لحم غنم مطبوخ").source_type, "لحوم حمراء");
  assert.equal(byName("صدر دجاج مشوي").source_type, "لحوم بيضاء (دواجن)");
  assert.equal(byName("عدس مطبوخ").source_type, "بقوليات");
});

test("نسبة الاحتياج للحصة: العدس (150غ) غني بالألياف والفولات", () => {
  const lentil = byName("عدس مطبوخ");
  const fiber = nutrientRows(lentil).find((r) => r.key === "fiber")!;
  assert.equal(fiber.amount, Math.round(lentil.fiber_100! * 1.5 * 10) / 10);
  assert.equal(fiber.pct, Math.round((lentil.fiber_100! * 1.5 / 28) * 100));
  assert.equal(fiber.level, "rich");
  assert.ok(matchesTag(lentil, "fiber"));
  assert.ok(matchesTag(lentil, "folate"));
  assert.ok(foodTags(lentil).some((t) => t.text === "غني بالألياف"));
});

test("الشارات بالعربي الصحيح، والعنصر الناقص في USDA ما يظهر", () => {
  const tags = foodTags(byName("فلفل رومي أحمر")).map((t) => t.text);
  assert.ok(tags.includes("غني بفيتامين C"), tags.join("، "));
  const rows = nutrientRows({ name_ar: "x", source_type: "خضار", serving_g: 100, serving_label: null, protein_100: 1, fiber_100: 2, micros: { iron: 1.8 } });
  assert.deepEqual(rows.map((r) => r.key), ["fiber", "protein", "iron"]);
  assert.equal(rows.find((r) => r.key === "iron")!.level, "good"); // 1.8 من 18 = 10%
  assert.equal(foodTags({ name_ar: "x", source_type: "خضار", serving_g: 100, serving_label: null, protein_100: 0, fiber_100: 3, micros: {} })[0].text, "مصدر جيد للألياف");
});

test("بدون حصة يُحسب لكل 100غ", () => {
  const r = nutrientRows({ name_ar: "x", source_type: "خضار", serving_g: null, serving_label: null, protein_100: 10, fiber_100: null, micros: null });
  assert.deepEqual(r.map((x) => [x.key, x.amount, x.pct]), [["protein", 10, 20]]);
});
