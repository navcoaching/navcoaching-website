// حاسبة السعرات والماكروز — منطق حساب خالص (بدون واجهة) حتى يسهل اختباره وتعديله.
// كل الثوابت القابلة للتعديل في أعلى الملف.

export type Sex = "male" | "female";
export type Goal = "gain" | "lose" | "maintain";
export type Level = "beginner" | "advanced";
export type ProteinPref = "moderate" | "high";

export type CalorieInput = {
  sex: Sex;
  age: number;
  weight: number; // كغ
  height: number; // سم
  bodyFat?: number | null; // %
  steps: number; // متوسط يومي
  goal: Goal;
  level: Level;
  protein: ProteinPref;
};

export type CalorieResult = {
  lbm: number;
  lbmEstimated: boolean; // لا توجد نسبة دهون ← الكتلة الخالية = الوزن الكلي (تقدير أقل دقة)
  formula: "katch" | "mifflin";
  bmr: number;
  activity: number;
  tdee: number;
  target: number;
  proteinG: number;
  proteinPerKg: number;
  fatG: number;
  carbsG: number;
  warnings: string[];
};

/** حدود الإدخال المقبولة */
export const LIMITS = {
  age: [15, 90], weight: [30, 250], height: [120, 230], bodyFat: [3, 60], steps: [0, 50000],
} as const;

/** عامل النشاط حسب متوسط الخطوات اليومية (الحد الأعلى غير شامل) */
export const STEP_FACTORS: { below: number; factor: number }[] = [
  { below: 5000, factor: 1.2 },
  { below: 7500, factor: 1.35 },
  { below: 10000, factor: 1.5 },
  { below: 12500, factor: 1.65 },
  { below: Infinity, factor: 1.8 },
];

/** فرق السعرات عن المحافظة حسب الهدف */
export const GOAL_DELTA: Record<Goal, number> = { gain: 400, lose: -400, maintain: 0 };

/** جرام بروتين لكل كغ من الكتلة الخالية: المبتدئ عند الحد الأدنى، والمتقدم عند الحد الأعلى */
export const PROTEIN_PER_KG_LBM: Record<ProteinPref, Record<Level, number>> = {
  moderate: { beginner: 1.6, advanced: 2.0 },
  high: { beginner: 2.4, advanced: 2.8 },
};

/** حد أدنى شائع للسعرات اليومية بدون إشراف مختص (تنبيه فقط، لا يغيّر الحساب) */
export const MIN_SAFE_KCAL: Record<Sex, number> = { male: 1500, female: 1200 };

/** نسبة سعرات الدهون من سعرات الهدف */
export const FAT_SHARE = 0.27;

export type FieldErrors = Partial<Record<keyof CalorieInput, string>>;

export function validate(i: Partial<Record<keyof CalorieInput, unknown>>): FieldErrors {
  const e: FieldErrors = {};
  const num = (k: "age" | "weight" | "height" | "steps" | "bodyFat", label: string, unit: string) => {
    const v = i[k];
    const [min, max] = LIMITS[k];
    if (typeof v !== "number" || !Number.isFinite(v)) e[k] = `اكتب ${label}.`;
    else if (v <= 0 && k !== "steps") e[k] = `${label} لازم يكون أكبر من صفر.`;
    else if (v < min || v > max) e[k] = `اكتب ${label} بين ${min} و ${max}${unit}.`;
  };
  if (i.sex !== "male" && i.sex !== "female") e.sex = "اختر الجنس.";
  num("age", "العمر", " سنة");
  if (typeof i.age === "number" && !Number.isInteger(i.age) && !e.age) e.age = "اكتب العمر رقماً صحيحاً.";
  num("weight", "الوزن", " كغ");
  num("height", "الطول", " سم");
  num("steps", "عدد الخطوات", " خطوة");
  if (i.bodyFat != null) num("bodyFat", "نسبة الدهون", "%");
  if (!["gain", "lose", "maintain"].includes(i.goal as string)) e.goal = "اختر هدفك.";
  if (!["beginner", "advanced"].includes(i.level as string)) e.level = "اختر مستواك في تمارين المقاومة.";
  if (!["moderate", "high"].includes(i.protein as string)) e.protein = "اختر كمية البروتين.";
  return e;
}

export const activityFactor = (steps: number) => STEP_FACTORS.find((s) => steps < s.below)!.factor;

export function calculateCalories(i: CalorieInput): CalorieResult {
  const warnings: string[] = [];
  const hasBf = i.bodyFat != null;

  // أ) الكتلة الخالية من الدهون
  const lbm = hasBf ? i.weight * (1 - i.bodyFat! / 100) : i.weight;
  if (!hasBf) warnings.push("بدون نسبة الدهون استخدمنا الوزن الكلي بدل الكتلة الخالية من الدهون، فالنتيجة أقل دقة، والبروتين قد يطلع أعلى من حاجتك إذا كانت نسبة دهونك مرتفعة.");

  // ب) معدل الأيض الأساسي
  const bmr = hasBf
    ? 370 + 21.6 * lbm // Katch-McArdle
    : 10 * i.weight + 6.25 * i.height - 5 * i.age + (i.sex === "male" ? 5 : -161); // Mifflin-St Jeor

  // ج) سعرات المحافظة
  const activity = activityFactor(i.steps);
  const tdee = bmr * activity;

  // د) سعرات الهدف
  const target = tdee + GOAL_DELTA[i.goal];

  if (target < MIN_SAFE_KCAL[i.sex]) warnings.push(`سعرات الهدف أقل من الحد الأدنى المتعارف عليه (${MIN_SAFE_KCAL[i.sex]} سعرة) بدون إشراف مختص. لا تنزل عنه قبل استشارة مختص.`);

  // هـ) البروتين حسب الكتلة الخالية
  const proteinPerKg = PROTEIN_PER_KG_LBM[i.protein][i.level];
  const proteinG = proteinPerKg * lbm;

  // و) الدهون
  const fatG = (target * FAT_SHARE) / 9;

  // ز) الكربوهيدرات = الباقي
  const carbKcal = target - proteinG * 4 - fatG * 9;
  const carbsG = carbKcal / 4;
  if (carbKcal < 0) warnings.push("سعرات البروتين والدهون أكبر من سعرات الهدف، فما بقي شيء للكربوهيدرات. اختر «بروتين معتدل» أو أدخل نسبة الدهون لنتيجة أدق.");
  else if (carbsG < 50) warnings.push("الكربوهيدرات المتبقية قليلة جداً. جرّب «بروتين معتدل» أو راجع مختصاً قبل تطبيقها.");

  return {
    lbm, lbmEstimated: !hasBf, formula: hasBf ? "katch" : "mifflin",
    bmr, activity, tdee, target, proteinG, proteinPerKg, fatG, carbsG: Math.max(0, carbsG), warnings,
  };
}
