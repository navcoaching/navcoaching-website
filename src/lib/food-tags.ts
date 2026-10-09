// تصنيف مصادر الأكل وقيمها الغذائية (الألياف والفيتامينات والمعادن) — منطق خالص بدون قاعدة بيانات.
// القيم لكل 100غ من USDA FoodData Central (SR Legacy)، والحكم على «غني بـ / مصدر جيد» لكل حصة الموقع:
// - الاحتياج اليومي (DV) للبالغين حسب ملصق الغذاء الأمريكي (FDA, 21 CFR 101.9).
// - «غني بـ» = 20% من الاحتياج أو أكثر للحصة، و«مصدر جيد» = 10–19% (نفس عتبات FDA في 21 CFR 101.54).

export const SOURCE_TYPES = [
  "لحوم حمراء", "لحوم بيضاء (دواجن)", "أسماك ومأكولات بحرية", "بيض", "ألبان وأجبان", "بقوليات",
  "حبوب ونشويات", "خضار نشوية", "خضار", "فواكه", "مكسرات وبذور", "دهون وزيوت",
  "مكملات", "حلويات ومحليات", "مشروبات", "صلصات",
] as const;

/** مجموعات أعلى من نوع المصدر، للتصفح السريع */
export const SOURCE_GROUPS: { label: string; types: readonly string[] }[] = [
  { label: "بروتينات حيوانية", types: ["لحوم حمراء", "لحوم بيضاء (دواجن)", "أسماك ومأكولات بحرية", "بيض", "ألبان وأجبان"] },
  { label: "بروتينات نباتية", types: ["بقوليات", "مكسرات وبذور"] },
  { label: "كربوهيدرات", types: ["حبوب ونشويات", "خضار نشوية", "فواكه"] },
  { label: "خضار", types: ["خضار"] },
  { label: "دهون", types: ["دهون وزيوت", "مكسرات وبذور"] },
  { label: "أخرى", types: ["مكملات", "حلويات ومحليات", "مشروبات", "صلصات"] },
];

export type MicroKey = "vit_a" | "vit_c" | "vit_d" | "vit_e" | "vit_k" | "vit_b6" | "vit_b12" | "folate"
  | "iron" | "calcium" | "potassium" | "magnesium" | "zinc";
export type Micros = Partial<Record<MicroKey, number>>;

/** العناصر: الاسم، الوحدة، والاحتياج اليومي (FDA) */
export const NUTRIENTS: { key: MicroKey | "fiber" | "protein"; label: string; unit: string; dv: number; kind: "vitamin" | "mineral" | "fiber" | "protein" }[] = [
  { key: "fiber", label: "الألياف", unit: "غ", dv: 28, kind: "fiber" },
  { key: "protein", label: "البروتين", unit: "غ", dv: 50, kind: "protein" },
  { key: "vit_a", label: "فيتامين A", unit: "ميكروغرام", dv: 900, kind: "vitamin" },
  { key: "vit_c", label: "فيتامين C", unit: "ملغ", dv: 90, kind: "vitamin" },
  { key: "vit_d", label: "فيتامين D", unit: "ميكروغرام", dv: 20, kind: "vitamin" },
  { key: "vit_e", label: "فيتامين E", unit: "ملغ", dv: 15, kind: "vitamin" },
  { key: "vit_k", label: "فيتامين K", unit: "ميكروغرام", dv: 120, kind: "vitamin" },
  { key: "vit_b6", label: "فيتامين B6", unit: "ملغ", dv: 1.7, kind: "vitamin" },
  { key: "vit_b12", label: "فيتامين B12", unit: "ميكروغرام", dv: 2.4, kind: "vitamin" },
  { key: "folate", label: "الفولات (B9)", unit: "ميكروغرام", dv: 400, kind: "vitamin" },
  { key: "iron", label: "الحديد", unit: "ملغ", dv: 18, kind: "mineral" },
  { key: "calcium", label: "الكالسيوم", unit: "ملغ", dv: 1300, kind: "mineral" },
  { key: "potassium", label: "البوتاسيوم", unit: "ملغ", dv: 4700, kind: "mineral" },
  { key: "magnesium", label: "المغنيسيوم", unit: "ملغ", dv: 420, kind: "mineral" },
  { key: "zinc", label: "الزنك", unit: "ملغ", dv: 11, kind: "mineral" },
];
export const RICH_PCT = 20;
export const GOOD_PCT = 10;

export type FoodDetail = {
  name_ar: string; source_type: string | null; serving_g: number | null; serving_label: string | null;
  protein_100: number; fiber_100: number | null; micros: Micros | null;
};
export type NutrientRow = { key: string; label: string; unit: string; kind: string; amount: number; pct: number; level: "rich" | "good" | null };

/** كمية كل عنصر ونسبته من الاحتياج اليومي لحصة الموقع (أو 100غ إذا ما فيه حصة). العنصر اللي ما له قيمة في USDA ما يظهر */
export function nutrientRows(f: FoodDetail): NutrientRow[] {
  const g = f.serving_g && f.serving_g > 0 ? f.serving_g : 100;
  const out: NutrientRow[] = [];
  for (const n of NUTRIENTS) {
    const per100 = n.key === "fiber" ? f.fiber_100 : n.key === "protein" ? f.protein_100 : f.micros?.[n.key as MicroKey];
    if (per100 == null) continue;
    const amount = (Number(per100) * g) / 100;
    const pct = Math.round((amount / n.dv) * 100);
    out.push({ key: n.key, label: n.label, unit: n.unit, kind: n.kind, amount: Math.round(amount * 10) / 10, pct,
      level: pct >= RICH_PCT ? "rich" : pct >= GOOD_PCT ? "good" : null });
  }
  return out;
}

/** «ب» + الاسم: بالألياف، بفيتامين C */
const bi = (label: string) => `ب${label}`;
/** «ل» + الاسم: للألياف، لفيتامين C */
const li = (label: string) => (label.startsWith("ال") ? `لل${label.slice(2)}` : `ل${label}`);

/** الشارات: «غني بالألياف»، «غني بفيتامين C»، «مصدر جيد للحديد»... مرتبة من الأعلى نسبة */
export function foodTags(f: FoodDetail): { key: string; text: string; level: "rich" | "good"; pct: number }[] {
  return nutrientRows(f).filter((r) => r.level).sort((a, b) => b.pct - a.pct).map((r) => ({
    key: r.key, level: r.level!, pct: r.pct,
    text: r.level === "rich" ? `غني ${bi(r.label)}` : `مصدر جيد ${li(r.label)}`,
  }));
}

/** فلاتر الدليل: «عالي الألياف»، «عالي البروتين»، أو عنصر معيّن */
export const TAG_FILTERS: { v: string; l: string }[] = [
  { v: "fiber", l: "عالي الألياف" },
  { v: "protein", l: "عالي البروتين" },
  { v: "vitamins", l: "غني بالفيتامينات (أي فيتامين)" },
  { v: "minerals", l: "غني بالمعادن (أي معدن)" },
  ...NUTRIENTS.filter((n) => n.kind === "vitamin" || n.kind === "mineral").map((n) => ({ v: n.key, l: `غني ${bi(n.label)}` })),
];

export function matchesTag(f: FoodDetail, tag: string): boolean {
  const rich = nutrientRows(f).filter((r) => r.level === "rich");
  if (tag === "vitamins") return rich.some((r) => r.kind === "vitamin");
  if (tag === "minerals") return rich.some((r) => r.kind === "mineral");
  return rich.some((r) => r.key === tag);
}
