// حاسبة توازن الطاقة (Henselmans Energy Balance Calculator) — منطق حساب خالص بدون واجهة.
// تحسب التوازن الفعلي للطاقة من التغيّر الحقيقي في تركيبة الجسم بين قياسين (مثل فحصي InBody)
// ومتوسط السعرات المأكولة خلال نفس الفترة، ومنها سعرات المحافظة الفعلية.
// الثوابت مطابقة لملف الإكسل المرجعي.

/** الطاقة القابلة للأيض لكل كغ (ميغاجول) — كما في ملف Henselmans */
export const MJ_PER_KG = { fat: 39.5, lean: 7.6 } as const;
/** سعرات لكل ميغاجول */
export const KCAL_PER_MJ = 238.8458966;

export type EnergyInput = {
  leanChange: number;   // تغيّر الكتلة الخالية من الدهون (كغ) موجب = زيادة
  fatChange: number;    // تغيّر كتلة الدهون (كغ) موجب = زيادة
  startDate: string;    // YYYY-MM-DD
  endDate: string;      // YYYY-MM-DD
  trainingKcal: number; // سعرات يوم التمرين
  trainingDays: number; // أيام التمرين في الأسبوع (0–7)، والباقي أيام راحة
  restKcal: number;     // سعرات يوم الراحة
};

export type EnergyResult = {
  leanMJ: number;
  fatMJ: number;
  netKcal: number;          // صافي التوازن خلال الفترة
  days: number;             // مدة الفترة بالأيام
  avgIntake: number;        // متوسط السعرات اليومية
  dailyBalance: number;     // التوازن اليومي (سالب = عجز، موجب = فائض)
  dailyBalancePct: number;  // نسبة التوازن من سعرات المحافظة
  maintenance: number;      // سعرات المحافظة الفعلية = المتوسط − التوازن اليومي
  warnings: string[];
};

export const LIMITS = { change: [-50, 50], kcal: [500, 10000], trainingDays: [0, 7] } as const;

const DAY = 86_400_000;
const parseDate = (s: string) => (/^\d{4}-\d{2}-\d{2}$/.test(s) ? Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10)) : NaN);
export const daysBetween = (a: string, b: string) => Math.round((parseDate(b) - parseDate(a)) / DAY);

export type FieldErrors = Partial<Record<keyof EnergyInput, string>>;

export function validate(i: Partial<Record<keyof EnergyInput, unknown>>): FieldErrors {
  const e: FieldErrors = {};
  const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
  for (const [k, label] of [["leanChange", "تغيّر الكتلة الخالية من الدهون"], ["fatChange", "تغيّر كتلة الدهون"]] as const) {
    const v = i[k];
    if (!isNum(v)) e[k] = `اكتب ${label} (اكتب 0 إذا ما تغيّر).`;
    else if (v < LIMITS.change[0] || v > LIMITS.change[1]) e[k] = `اكتب ${label} بين ${LIMITS.change[0]} و ${LIMITS.change[1]} كغ.`;
  }
  for (const [k, label] of [["trainingKcal", "سعرات يوم التمرين"], ["restKcal", "سعرات يوم الراحة"]] as const) {
    const v = i[k];
    if (!isNum(v)) e[k] = `اكتب ${label}.`;
    else if (v <= 0) e[k] = `${label} لازم تكون أكبر من صفر.`;
    else if (v < LIMITS.kcal[0] || v > LIMITS.kcal[1]) e[k] = `اكتب ${label} بين ${LIMITS.kcal[0]} و ${LIMITS.kcal[1]}.`;
  }
  const td = i.trainingDays;
  if (!isNum(td) || !Number.isInteger(td) || td < 0 || td > 7) e.trainingDays = "اختر عدد أيام التمرين (0–7).";
  const s = String(i.startDate ?? ""), en = String(i.endDate ?? "");
  if (Number.isNaN(parseDate(s))) e.startDate = "اختر تاريخ القياس الأول.";
  if (Number.isNaN(parseDate(en))) e.endDate = "اختر تاريخ القياس الثاني.";
  else if (!e.startDate && daysBetween(s, en) < 1) e.endDate = "تاريخ القياس الثاني لازم يكون بعد الأول.";
  return e;
}

export function calculateEnergyBalance(i: EnergyInput): EnergyResult {
  const warnings: string[] = [];
  const leanMJ = i.leanChange * MJ_PER_KG.lean;
  const fatMJ = i.fatChange * MJ_PER_KG.fat;
  const netKcal = (leanMJ + fatMJ) * KCAL_PER_MJ;
  const days = daysBetween(i.startDate, i.endDate);
  const restDays = 7 - i.trainingDays;
  const avgIntake = (i.trainingKcal * i.trainingDays + i.restKcal * restDays) / 7;
  const dailyBalance = netKcal / days;
  const maintenance = avgIntake - dailyBalance;
  const dailyBalancePct = maintenance > 0 ? dailyBalance / maintenance : 0;

  if (days < 14) warnings.push("المدة أقل من أسبوعين، فالنتيجة تتأثر كثيراً بتقلبات الماء وأخطاء جهاز القياس. الأفضل 4 أسابيع أو أكثر.");
  if (maintenance <= 0) warnings.push("النتيجة غير منطقية: راجع أرقام التغيّر في الجسم والسعرات المأكولة.");
  return { leanMJ, fatMJ, netKcal, days, avgIntake, dailyBalance, dailyBalancePct, maintenance, warnings };
}

// =====================================================================
// حاسبة السعرات اليومية (Henselmans Energy Intake Calculator 2026)
// تقدير سعرات المحافظة والهدف من الوزن وتركيبة الجسم والتمرين. الثوابت والمعادلات مطابقة لملف الإكسل المرجعي.
// =====================================================================

export type BmrMethod = "cunningham" | "tenhaaf" | "tinsley";
export type IntakeInput = {
  method: BmrMethod;
  weight: number;          // كغ
  bodyFat?: number | null; // % (Cunningham)
  heightCm?: number | null;// سم (Ten Haaf)
  age?: number | null;     // سنة (Ten Haaf)
  sex?: "male" | "female" | null; // (Ten Haaf)
  paf: number;             // عامل النشاط البدني خارج التمرين
  tef?: number;            // عامل التأثير الحراري للطعام (افتراضي 1.2 كما في الملف)
  minutes: number;         // مدة جلسة تمرين المقاومة (دقيقة)
  trainingDays: number;    // أيام التمرين في الأسبوع
  ebFactor: number;        // عامل توازن الطاقة: 1 محافظة، أقل من 1 عجز، أكثر من 1 فائض
};
export type IntakeResult = {
  ffm: number | null; bmr: number; trainingEE: number; restDayEE: number; trainingDayEE: number;
  maintenance: number; target: number; restDayTarget: number; trainingDayTarget: number;
};

export const DEFAULT_TEF = 1.2;
/** عامل النشاط البدني خارج التمرين (PAF) — خيارات حاسبة الموقع */
export const PAF_LEVELS = [
  { v: "1.0", l: "قليل الحركة (أقل من 5,000 خطوة)" },
  { v: "1.1", l: "خفيف (5,000–7,500 خطوة)" },
  { v: "1.2", l: "متوسط (7,500–10,000 خطوة)" },
  { v: "1.3", l: "نشيط (10,000–12,500 خطوة)" },
  { v: "1.4", l: "نشيط جداً (+12,500 خطوة أو عمل بدني)" },
] as const;
/** عامل توازن الطاقة: أقل من 1 = عجز، أكثر من 1 = فائض */
export const EB_GOALS = [
  { v: "0.75", l: "تنشيف سريع (عجز 25٪)" },
  { v: "0.8", l: "تنشيف (عجز 20٪)" },
  { v: "0.9", l: "تنشيف تدريجي (عجز 10٪)" },
  { v: "1", l: "المحافظة على الوزن" },
  { v: "1.05", l: "تضخيم نظيف (فائض 5٪)" },
  { v: "1.1", l: "تضخيم (فائض 10٪)" },
] as const;
/** مصروف تمرين المقاومة: 0.1 سعرة لكل كغ لكل دقيقة */
export const TRAINING_KCAL_PER_KG_MIN = 0.1;

export const INTAKE_LIMITS = { weight: [30, 250], bodyFat: [3, 60], heightCm: [120, 230], age: [15, 90], minutes: [0, 240] } as const;

export function bmrFor(i: IntakeInput): { bmr: number; ffm: number | null } {
  if (i.method === "cunningham") {
    const ffm = i.weight * (1 - (i.bodyFat ?? 0) / 100);
    return { bmr: 370 + 21.6 * ffm, ffm };                  // Cunningham et al. (1991)
  }
  if (i.method === "tinsley") return { bmr: 24.8 * i.weight + 10, ffm: null }; // Tinsley et al. (2018)
  const h = (i.heightCm ?? 0) / 100;
  const sex = i.sex === "male" ? 1 : 0;
  const kj = 49.94 * i.weight + 2459.053 * h - 34.014 * (i.age ?? 0) + 799.257 * sex + 122.502; // Ten Haaf & Weijs (2014), كيلوجول
  return { bmr: kj / 4.184, ffm: null };
}

export function calculateIntake(i: IntakeInput): IntakeResult {
  const tef = i.tef ?? DEFAULT_TEF;
  const { bmr, ffm } = bmrFor(i);
  const trainingEE = TRAINING_KCAL_PER_KG_MIN * i.weight * i.minutes;
  const restDayEE = bmr * i.paf * tef;
  const trainingDayEE = (bmr * i.paf + trainingEE) * tef;
  const maintenance = (trainingDayEE * i.trainingDays + restDayEE * (7 - i.trainingDays)) / 7;
  return {
    ffm, bmr, trainingEE, restDayEE, trainingDayEE, maintenance,
    target: maintenance * i.ebFactor, restDayTarget: restDayEE * i.ebFactor, trainingDayTarget: trainingDayEE * i.ebFactor,
  };
}

export type IntakeErrors = Partial<Record<keyof IntakeInput, string>>;
export function validateIntake(i: Partial<Record<keyof IntakeInput, unknown>>): IntakeErrors {
  const e: IntakeErrors = {};
  const num = (k: "weight" | "bodyFat" | "heightCm" | "age" | "minutes", label: string, unit: string) => {
    const v = i[k]; const [min, max] = INTAKE_LIMITS[k];
    if (typeof v !== "number" || !Number.isFinite(v)) e[k] = `اكتب ${label}.`;
    else if (v <= 0 && k !== "minutes") e[k] = `${label} لازم يكون أكبر من صفر.`;
    else if (v < min || v > max) e[k] = `اكتب ${label} بين ${min} و ${max}${unit}.`;
  };
  if (!["cunningham", "tenhaaf", "tinsley"].includes(i.method as string)) e.method = "اختر طريقة الحساب.";
  num("weight", "الوزن", " كغ");
  num("minutes", "مدة التمرين", " دقيقة");
  if (i.method === "cunningham") num("bodyFat", "نسبة الدهون", "%");
  if (i.method === "tenhaaf") {
    num("heightCm", "الطول", " سم");
    num("age", "العمر", " سنة");
    if (i.sex !== "male" && i.sex !== "female") e.sex = "اختر الجنس.";
  }
  const td = i.trainingDays;
  if (typeof td !== "number" || !Number.isInteger(td) || td < 0 || td > 7) e.trainingDays = "اختر عدد أيام التمرين.";
  if (typeof i.paf !== "number" || i.paf < 1 || i.paf > 2) e.paf = "اختر مستوى نشاطك.";
  if (typeof i.ebFactor !== "number" || i.ebFactor < 0.6 || i.ebFactor > 1.3) e.ebFactor = "اختر هدفك.";
  return e;
}
