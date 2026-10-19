// يضيف أصنافاً جديدة لقاعدة الأكل (db/seed/foods.json) من ملفات USDA SR Legacy المحلية (.data/usda-sr)،
// بنفس حقول الأصناف الموجودة: القيم لكل 100غ، الألياف، الفيتامينات والمعادن. لا يغيّر الأصناف الموجودة.
// الاستخدام: node scripts/usda-add-foods.mjs   (القائمة في NEW أدناه: الاسم العربي ← وصف USDA حرفياً)
//            node scripts/usda-add-foods.mjs --check "<وصف USDA>"   (يطبع القيم بدون حفظ)
import { readFileSync, writeFileSync } from "node:fs";

const dir = ".data/usda-sr";
const NUT = { 1003: "protein", 1004: "fat", 1005: "carbs", 1008: "kcal", 1079: "fiber",
  1162: "vit_c", 1106: "vit_a", 1114: "vit_d", 1109: "vit_e", 1185: "vit_k", 1190: "folate", 1178: "vit_b12", 1175: "vit_b6",
  1089: "iron", 1087: "calcium", 1092: "potassium", 1090: "magnesium", 1095: "zinc" };
const MICROS = ["vit_c", "vit_a", "vit_d", "vit_e", "vit_k", "folate", "vit_b12", "vit_b6", "iron", "calcium", "potassium", "magnesium", "zinc"];

function* rows(text) {
  let row = [], field = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; } else field += ch; }
    else if (ch === '"') q = true;
    else if (ch === ",") { row.push(field); field = ""; }
    else if (ch === "\n") { row.push(field.replace(/\r$/, "")); yield row; row = []; field = ""; }
    else field += ch;
  }
  if (field || row.length) { row.push(field); yield row; }
}
const table = (file) => { const it = rows(readFileSync(`${dir}/${file}`, "utf8")); return { head: it.next().value, it }; };

export function usdaValues(descs) {
  const want = new Map(descs.map((d) => [d.toLowerCase(), null]));
  { const { head, it } = table("food.csv"); const iId = head.indexOf("fdc_id"), iD = head.indexOf("description");
    for (const r of it) { const d = (r[iD] ?? "").toLowerCase(); if (want.has(d) && !want.get(d)) want.set(d, r[iId]); } }
  const ids = new Set([...want.values()].filter(Boolean)), vals = new Map();
  { const { head, it } = table("food_nutrient.csv"); const iF = head.indexOf("fdc_id"), iN = head.indexOf("nutrient_id"), iA = head.indexOf("amount");
    for (const r of it) { if (!ids.has(r[iF]) || !NUT[r[iN]]) continue; const v = vals.get(r[iF]) ?? {}; v[NUT[r[iN]]] = Number(r[iA]); vals.set(r[iF], v); } }
  return new Map(descs.map((d) => { const id = want.get(d.toLowerCase()); return [d, id ? { id, ...(vals.get(id) ?? {}) } : null]; }));
}

const r1 = (n) => Math.round(n * 10) / 10;
// نوع المصدر من قائمة SOURCE_TYPES (src/lib/food-tags.ts)
export const SOURCE_TYPE = {"ثوم": "خضار", "معجون طماطم": "صلصات", "صلصة طماطم": "صلصات", "خردل": "صلصات", "صلصة رانش": "صلصات", "كريمة طبخ": "ألبان وأجبان", "جبنة كريمية لايت (فيلادلفيا لايت)": "ألبان وأجبان", "جبنة بارميزان مبشورة": "ألبان وأجبان", "جبنة شرائح (مطبوخة)": "ألبان وأجبان", "جبنة بروفولون (بديل القشقوان)": "ألبان وأجبان", "حليب بودرة خالي الدسم": "ألبان وأجبان", "دقيق بر (أسمر)": "حبوب ونشويات", "دقيق أبيض": "حبوب ونشويات", "نشا الذرة": "حبوب ونشويات", "كاكاو بودرة (بدون سكر)": "حلويات ومحليات", "باكنج باودر": "حلويات ومحليات", "شوكولاتة بالحليب": "حلويات ومحليات", "آيسكريم فانيلا": "حلويات ومحليات", "بسكويت سادة (جراهام)": "حلويات ومحليات", "كريمة خفق بودرة (دريم ويب)": "حلويات ومحليات", "خبز بريوش": "حبوب ونشويات", "بيكان": "مكسرات وبذور", "بطاطس نيئة": "خضار نشوية", "لحم بقري مفروم 90% نيء": "لحوم حمراء", "تندرلوين بقري نيء (بدون دهن)": "لحوم حمراء", "قهوة سريعة التحضير (بودرة)": "مشروبات"};
export function toFood([ar, desc, category, serving_g, serving_label], v) {
  return { name_ar: ar, name_en: desc, category, kcal_100: r1(v.kcal ?? v.protein * 4 + v.carbs * 4 + v.fat * 9),
    protein_100: r1(v.protein), carbs_100: r1(v.carbs), fat_100: r1(v.fat), serving_g, serving_label, source_ref: v.id,
    source_type: SOURCE_TYPE[ar] ?? category, fiber_100: r1(v.fiber ?? 0), micros: Object.fromEntries(MICROS.map((k) => [k, v[k] ?? 0])) };
}

// الأصناف الجديدة (لوصفات الحساب الصحي وغيرها)
export const NEW = [
  ["ثوم", "Garlic, raw", "خضار", 5, "فص ونص"],
  ["معجون طماطم", "Tomato products, canned, paste, without salt added (Includes foods for USDA's Food Distribution Program)", "صوصات", 16, "ملعقة كبيرة"],
  ["صلصة طماطم", "Tomato products, canned, sauce", "صوصات", 60, "ربع كوب"],
  ["خردل", "Mustard, prepared, yellow", "صوصات", 5, "ملعقة صغيرة"],
  ["صلصة رانش", "Salad dressing, ranch dressing, regular", "صوصات", 15, "ملعقة كبيرة"],
  ["كريمة طبخ", "Cream, fluid, light (coffee cream or table cream)", "بيض وألبان", 30, "ملعقتين كبار"],
  ["جبنة كريمية لايت (فيلادلفيا لايت)", "Cheese, cream, low fat", "بيض وألبان", 30, "ملعقتين كبار"],
  ["جبنة بارميزان مبشورة", "Cheese, parmesan, grated", "بيض وألبان", 10, "ملعقة كبيرة"],
  ["جبنة شرائح (مطبوخة)", "Cheese, pasteurized process, American, fortified with vitamin D", "بيض وألبان", 20, "شريحة"],
  ["جبنة بروفولون (بديل القشقوان)", "Cheese, provolone", "بيض وألبان", 25, "شريحة"],
  ["حليب بودرة خالي الدسم", "Milk, dry, nonfat, regular, without added vitamin A and vitamin D", "بيض وألبان", 10, "ملعقة كبيرة"],
  ["دقيق بر (أسمر)", "Wheat flour, whole-grain (Includes foods for USDA's Food Distribution Program)", "حبوب ونشويات", 30, "ربع كوب"],
  ["دقيق أبيض", "Wheat flour, white, all-purpose, enriched, unbleached", "حبوب ونشويات", 30, "ربع كوب"],
  ["نشا الذرة", "Cornstarch", "حبوب ونشويات", 8, "ملعقة كبيرة"],
  ["كاكاو بودرة (بدون سكر)", "Cocoa, dry powder, unsweetened", "حلويات ومشروبات", 5, "ملعقة كبيرة"],
  ["باكنج باودر", "Leavening agents, baking powder, double-acting, straight phosphate", "حلويات ومشروبات", 4, "ملعقة صغيرة"],
  ["شوكولاتة بالحليب", "Candies, milk chocolate", "حلويات ومشروبات", 20, "مربعين"],
  ["آيسكريم فانيلا", "Ice creams, vanilla", "حلويات ومشروبات", 66, "نص كوب"],
  ["بسكويت سادة (جراهام)", "Cookies, graham crackers, plain or honey (includes cinnamon)", "حلويات ومشروبات", 15, "حبتين"],
  ["كريمة خفق بودرة (دريم ويب)", "Dessert topping, powdered", "حلويات ومشروبات", 10, "ملعقتين كبار"],
  ["خبز بريوش", "Bread, egg", "خبز", 40, "شريحة"],
  ["بيكان", "Nuts, pecans", "دهون ومكسرات", 15, "حفنة صغيرة"],
  ["بطاطس نيئة", "Potatoes, flesh and skin, raw", "حبوب ونشويات", 150, "حبة متوسطة"],
  ["لحم بقري مفروم 90% نيء", "Beef, ground, 90% lean meat / 10% fat, raw", "لحوم ودواجن", 120, "قطعة برجر"],
  ["تندرلوين بقري نيء (بدون دهن)", "Beef, tenderloin, steak, separable lean only, trimmed to 1/8\" fat, select, raw", "لحوم ودواجن", 150, "قطعة"],
  ["قهوة سريعة التحضير (بودرة)", "Beverages, coffee, instant, regular, powder", "حلويات ومشروبات", 2, "ملعقة صغيرة"],
];

if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv[2] === "--check") {
    const d = process.argv[3]; console.log(JSON.stringify(usdaValues([d]).get(d)));
  } else {
    const foods = JSON.parse(readFileSync("db/seed/foods.json", "utf8"));
    const have = new Set(foods.map((f) => f.name_ar));
    const todo = NEW.filter(([ar]) => !have.has(ar));
    const vals = usdaValues(todo.map((n) => n[1]));
    const missing = [];
    for (const n of todo) { const v = vals.get(n[1]); if (!v || v.protein == null) { missing.push(n[1]); continue; } foods.push(toFood(n, v)); console.log("+", n[0], "—", toFood(n, v).kcal_100, "سعرة/100غ"); }
    writeFileSync("db/seed/foods.json", JSON.stringify(foods, null, 1));
    if (missing.length) { console.log("✗ لم تُطابَق:"); for (const m of missing) console.log("  -", m); process.exitCode = 1; }
  }
}
