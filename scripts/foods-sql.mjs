// يولّد SQL استيراد قاعدة الأكل من db/seed/foods.json (مصدرها USDA SR Legacy عبر scripts/usda-foods.mjs).
// آمن للتكرار: لا يستبدل صنفاً موجوداً بنفس الاسم العربي (حتى لا تضيع تعديلات المدربة).
import { existsSync, readFileSync } from "node:fs";

export function foodsSql() {
  const path = new URL("../db/seed/foods.json", import.meta.url);
  if (!existsSync(path)) return "";
  const json = JSON.stringify(JSON.parse(readFileSync(path, "utf8")));
  if (json.includes("$fd$")) throw new Error("foods.json يحتوي $fd$");
  return `INSERT INTO foods (name_ar, name_en, category, kcal_100, protein_100, carbs_100, fat_100, serving_g, serving_label, source, source_ref,
                   source_type, fiber_100, micros)
SELECT x.name_ar, x.name_en, x.category, x.kcal_100, x.protein_100, x.carbs_100, x.fat_100, x.serving_g, x.serving_label, 'usda', x.source_ref,
       x.source_type, x.fiber_100, x.micros
  FROM jsonb_to_recordset($fd$${json}$fd$::jsonb) AS x(name_ar text, name_en text, category text, kcal_100 numeric, protein_100 numeric,
    carbs_100 numeric, fat_100 numeric, serving_g numeric, serving_label text, source_ref text, source_type text, fiber_100 numeric, micros jsonb)
ON CONFLICT ((lower(trim(name_ar)))) DO NOTHING;
`;
}

/** تعبئة نوع المصدر والألياف والفيتامينات للأصناف الموجودة من USDA (بمرجع fdcId)، بدون لمس الاسم أو الماكروز أو الحصة */
export function foodDetailsSql() {
  const rows = JSON.parse(readFileSync(new URL("../db/seed/foods.json", import.meta.url), "utf8"))
    .map((f) => ({ source_ref: f.source_ref, source_type: f.source_type, fiber_100: f.fiber_100, micros: f.micros }));
  const json = JSON.stringify(rows);
  if (json.includes("$fd$")) throw new Error("foods.json يحتوي $fd$");
  return `UPDATE foods f SET source_type = coalesce(f.source_type, x.source_type), fiber_100 = x.fiber_100, micros = x.micros, updated_at = now()
  FROM jsonb_to_recordset($fd$${json}$fd$::jsonb) AS x(source_ref text, source_type text, fiber_100 numeric, micros jsonb)
 WHERE f.source = 'usda' AND f.source_ref = x.source_ref;
`;
}
