// منتجات ماركات (ندى والمراعي): حليب بروتين وزبادي يوناني، بقيم الملصق على مواقع الشركتين الرسمية لكل 100 مل/غ.
// المرجع في source_ref. إن اختلفت سعرات الملصق عن حساب الماكروز بأكثر من 10 سعرات تُخزَّن سعرات الماكروز (كما يحسبها التطبيق).
// آمن للتكرار: لا يستبدل صنفاً موجوداً بنفس الاسم العربي.
import { readFileSync, writeFileSync } from "node:fs";

export const brandFoods = () => JSON.parse(readFileSync(new URL("../db/seed/brand-foods.json", import.meta.url), "utf8"));
export function brandFoodsSql() {
  const rows = brandFoods().map((x) => ({ name_ar: x.n, name_en: x.en, category: x.cat, kcal_100: x.kcal, protein_100: x.p, carbs_100: x.c, fat_100: x.f,
    serving_g: x.sv, serving_label: x.sl, source_ref: x.ref.slice(0, 40), source_type: "ألبان وأجبان" }));
  const json = JSON.stringify(rows);
  if (json.includes("$bf$")) throw new Error("brand-foods يحتوي $bf$");
  return `INSERT INTO foods (name_ar, name_en, category, kcal_100, protein_100, carbs_100, fat_100, serving_g, serving_label, source, source_ref, source_type)
SELECT x.name_ar, x.name_en, x.category, x.kcal_100, x.protein_100, x.carbs_100, x.fat_100, x.serving_g, x.serving_label, 'coach', x.source_ref, x.source_type
  FROM jsonb_to_recordset($bf$${json}$bf$::jsonb) AS x(name_ar text, name_en text, category text, kcal_100 numeric, protein_100 numeric, carbs_100 numeric,
    fat_100 numeric, serving_g numeric, serving_label text, source_ref text, source_type text)
ON CONFLICT ((lower(trim(name_ar)))) DO NOTHING;
`;
}
if (process.argv[1]?.endsWith("brand-foods-sql.mjs")) {
  const sql = `-- منتجات ندى والمراعي (حليب بروتين وزبادي يوناني) من المواقع الرسمية. بيانات فقط، آمن للتكرار.
BEGIN;
${brandFoodsSql()}COMMIT;
`;
  writeFileSync(new URL("../db/updates/2026-10-05-brand-foods.sql", import.meta.url), sql);
  console.log(`rows=${brandFoods().length} bytes=${sql.length}`);
}
