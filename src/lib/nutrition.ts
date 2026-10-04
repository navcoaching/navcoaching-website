// منطق التغذية (بدون واجهة) — مطابق لأوراق «التعليمات» و«تغذية ١–٥» و«Macro Log»:
//   السعرات = بروتين × 4 + كارب × 4 + دهون × 9
//   المتبقي = الهدف − مجموع اليوم (موجب = متبقٍ، سالب = تجاوز)

export type Macros = { protein: number; carbs: number; fat: number };
export type Target = { kcal: number | null; protein: number | null; carbs: number | null; fat: number | null };

export const MEAL_KINDS = { breakfast: "الفطور", lunch: "الغداء", dinner: "العشاء", snack: "سناك" } as const;
export type MealKind = keyof typeof MEAL_KINDS;
export const MEAL_ICON: Record<MealKind, string> = { breakfast: "🌅", lunch: "☀️", dinner: "🌙", snack: "🍎" };

export const kcalOf = (m: Macros) => Number(m.protein) * 4 + Number(m.carbs) * 4 + Number(m.fat) * 9;
const r1 = (v: number) => Math.round(v * 10) / 10;

export function sumMacros(list: readonly Macros[]): Macros & { kcal: number } {
  const t = list.reduce((a, x) => ({ protein: a.protein + Number(x.protein), carbs: a.carbs + Number(x.carbs), fat: a.fat + Number(x.fat) }), { protein: 0, carbs: 0, fat: 0 });
  return { protein: r1(t.protein), carbs: r1(t.carbs), fat: r1(t.fat), kcal: r1(kcalOf(t)) };
}

/** المتبقي من الهدف لكل قيمة، ونسبة الاكتمال (null إذا الهدف غير محدد) */
export function remaining(target: Target, total: Macros & { kcal: number }) {
  const row = (goal: number | null, got: number) => ({ goal, got, left: goal == null ? null : r1(goal - got), pct: goal ? got / goal : null });
  return { kcal: row(target.kcal, total.kcal), protein: row(target.protein, total.protein), carbs: row(target.carbs, total.carbs), fat: row(target.fat, total.fat) };
}

/** هل السعرات المكتوبة تطابق الماكروز؟ (مثل تنبيه ورقة التعليمات) */
export function targetCheck(t: Target): { fromMacros: number; diff: number; ok: boolean } | null {
  if (t.kcal == null || t.protein == null || t.carbs == null || t.fat == null) return null;
  const fromMacros = Math.round(kcalOf({ protein: t.protein, carbs: t.carbs, fat: t.fat }));
  const diff = t.kcal - fromMacros;
  return { fromMacros, diff, ok: Math.abs(diff) <= 50 };
}

/** قواعد التغذية الافتراضية (من ورقة «التعليمات» في قالب ملف التدريب) — تُعدَّل لكل متدرب */
export const DEFAULT_RULES = [
  "الأولوية اليومية: ١- البروتين  ٢- الدهون الصحية  ٣- الكارب (تراكمي، ويمكن تعويضه خلال الأسبوع)",
  "تدوير الكارب: أيام التمرين تُزاد الكمية، وأيام الراحة تُقلَّل. عند وجود أي استفسار تواصل مع المدربة.",
  "الصيام: لا تتجاوز 12 ساعة صيام.",
  "الوزن والقياسات: يُسجَّل الوزن 3 مرات أسبوعياً، وتُؤخذ القياسات صباح يوم المراجعة على معدة فارغة.",
].join("\n");

export const IMPORTANCE = ["مهم جداً", "مُنصَح به", "اختياري", "عند الحاجة فقط"] as const;

export type Per100 = { protein_100: number; carbs_100: number; fat_100: number; kcal_100?: number | null };
/** ماكروز كمية بالغرام من قيم 100غ (نفس حساب app.log_food_grams) */
export function scaleFood(f: Per100, grams: number) {
  const k = grams / 100;
  const p = Math.round(Number(f.protein_100) * k * 10) / 10, c = Math.round(Number(f.carbs_100) * k * 10) / 10, fat = Math.round(Number(f.fat_100) * k * 10) / 10;
  return { protein: p, carbs: c, fat, kcal: Math.round(kcalOf({ protein: p, carbs: c, fat })) };
}

/** قوالب الجداول القريبة من هدف السعرات: فرق 200 سعرة أو أقل، الأقرب أولاً. «قريب جداً» = 100 أو أقل */
export function plansNear<T extends { total: { kcal: number } }>(plans: T[], kcal: number | null | undefined, max = 200): (T & { diff: number; close: boolean })[] {
  if (!kcal) return [];
  return plans
    .map((p) => ({ ...p, diff: Math.round(p.total.kcal - kcal) }))
    .filter((p) => p.total.kcal > 0 && Math.abs(p.diff) <= max)
    .sort((a, b) => Math.abs(a.diff) - Math.abs(b.diff))
    .map((p) => ({ ...p, close: Math.abs(p.diff) <= 100 }));
}

/**
 * اسم الوجبة للعرض. بعض العناوين في القوالب مجرد «الفطور»، أو «الغداء — شورما دجاج» (النوع داخل الاسم).
 * نحذف بادئة النوع، وإن لم يبقَ اسم نستعمل أسماء الأطعمة فيها، وآخر الأمر عنوانها كما هو.
 */
export function mealName(kind: MealKind, title: string, foods?: string | null): string {
  const label = MEAL_KINDS[kind];
  const t = title.trim();
  const stripped = t.replace(new RegExp(`^${label}\\s*[—–:\\-]+\\s*`), "").trim();
  if (stripped && stripped !== label && stripped !== t) return stripped;
  if (t && t !== label) return t;
  const f = (foods ?? "").split("،").map((x) => x.trim()).filter(Boolean);
  return f.length ? f.slice(0, 3).join(" + ") : t;
}
