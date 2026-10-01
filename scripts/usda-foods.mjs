// يولّد db/seed/foods.json من ملفات USDA FoodData Central — SR Legacy (CSV، ملكية عامة CC0)
// حسب خريطة db/seed/foods-map.json (الاسم العربي ← وصف الصنف في USDA حرفياً). لا توجد أي قيمة مكتوبة يدوياً.
// الاستخدام: node scripts/usda-foods.mjs [مجلد CSV] — يحمّل الملف تلقائياً إن لم يوجد المجلد.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

const URL_ZIP = "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip";
const dir = process.argv[2] ?? ".data/usda-sr";
if (!existsSync(`${dir}/food.csv`)) {
  mkdirSync(dir, { recursive: true });
  const res = await fetch(URL_ZIP);
  if (!res.ok) throw new Error(`تحميل USDA فشل: ${res.status}`);
  writeFileSync(`${dir}/sr.zip`, Buffer.from(await res.arrayBuffer()));
  execFileSync("python3", ["-c", `import zipfile,os,shutil
z=zipfile.ZipFile('${dir}/sr.zip')
for n in z.namelist():
  b=os.path.basename(n)
  if b in ('food.csv','food_nutrient.csv'):
    with z.open(n) as s, open(os.path.join('${dir}',b),'wb') as d: shutil.copyfileobj(s,d)`]);
}

// محلل CSV بسيط يدعم الاقتباس
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
const table = (file) => { const it = rows(readFileSync(`${dir}/${file}`, "utf8")); const head = it.next().value; return { head, it }; };

const map = JSON.parse(readFileSync("db/seed/foods-map.json", "utf8")).items;
const wanted = new Map(map.map(([, desc]) => [desc.toLowerCase(), null]));
{ const { head, it } = table("food.csv"); const iId = head.indexOf("fdc_id"), iDesc = head.indexOf("description");
  for (const r of it) { const d = (r[iDesc] ?? "").toLowerCase(); if (wanted.has(d) && !wanted.get(d)) wanted.set(d, r[iId]); } }
const ids = new Set([...wanted.values()].filter(Boolean));
const NUT = { "1003": "protein", "1004": "fat", "1005": "carbs", "1008": "kcal" };
const values = new Map();
{ const { head, it } = table("food_nutrient.csv"); const iF = head.indexOf("fdc_id"), iN = head.indexOf("nutrient_id"), iA = head.indexOf("amount");
  for (const r of it) { if (!ids.has(r[iF]) || !NUT[r[iN]]) continue; const v = values.get(r[iF]) ?? {}; v[NUT[r[iN]]] = Number(r[iA]); values.set(r[iF], v); } }

const out = [], missing = [];
for (const [ar, desc, category, serving_g, serving_label] of map) {
  const id = wanted.get(desc.toLowerCase());
  const v = id && values.get(id);
  if (!v || v.protein == null || v.fat == null || v.carbs == null) { missing.push(desc); continue; }
  const r1 = (n) => Math.round(n * 10) / 10;
  out.push({ name_ar: ar, name_en: desc, category, kcal_100: r1(v.kcal ?? v.protein * 4 + v.carbs * 4 + v.fat * 9),
    protein_100: r1(v.protein), carbs_100: r1(v.carbs), fat_100: r1(v.fat), serving_g, serving_label, source_ref: id });
}
writeFileSync("db/seed/foods.json", JSON.stringify(out, null, 1));
console.log(`✓ db/seed/foods.json: ${out.length} صنفاً`);
if (missing.length) { console.log("✗ لم تُطابَق (صحّحي الوصف في foods-map.json):"); for (const m of missing) console.log("  -", m); }
