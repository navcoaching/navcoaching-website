// يحسب قيم وصفة من مكوناتها بالغرام (basis) من قاعدة الأكل db/seed/foods.json (USDA)، بدون أي رقم من الذاكرة.
// التوابل والأعشاب والليمون غير محسوبة (تُذكر في المكونات فقط).
import { readFileSync } from "node:fs";

const foods = JSON.parse(readFileSync(new URL("../db/seed/foods.json", import.meta.url), "utf8"));
const byName = new Map(foods.map((f) => [f.name_ar, f]));
const r1 = (v) => Math.round(v * 10) / 10;

export function calcRecipe(basis) {
  const t = { protein: 0, carbs: 0, fat: 0, fiber: 0 };
  for (const { food, g } of basis) {
    const f = byName.get(food);
    if (!f) throw new Error(`صنف غير موجود في قاعدة الأكل: ${food}`);
    t.protein += (f.protein_100 * g) / 100;
    t.carbs += (f.carbs_100 * g) / 100;
    t.fat += (f.fat_100 * g) / 100;
    t.fiber += ((f.fiber_100 ?? 0) * g) / 100;
  }
  const out = { protein: r1(t.protein), carbs: r1(t.carbs), fat: r1(t.fat), fiber: r1(t.fiber) };
  return { ...out, kcal_book: Math.round(4 * out.protein + 4 * out.carbs + 9 * out.fat) };
}

// تحقق: كل وصفة لها basis تطابق قيمها المحفوظة (node scripts/recipe-calc.mjs)
if (import.meta.url === `file://${process.argv[1]}`) {
  const recipes = JSON.parse(readFileSync(new URL("../db/seed/recipes.json", import.meta.url), "utf8"));
  let bad = 0;
  for (const r of recipes.filter((x) => x.basis)) {
    let c;
    try { c = calcRecipe(r.basis); } catch (e) { console.log("·", r.id, "تُتجاوز:", e.message); continue; }
    const diff = ["protein", "carbs", "fat"].filter((k) => Math.abs(c[k] - r[k]) > 0.15);
    if (diff.length) { bad++; console.log("✗", r.id, diff.map((k) => `${k}: محفوظ ${r[k]} ≠ محسوب ${c[k]}`).join("، ")); }
  }
  console.log(bad ? `${bad} وصفة مختلفة` : `✓ كل الوصفات المحسوبة (${recipes.filter((x) => x.basis).length}) مطابقة لقاعدة الأكل`);
}
