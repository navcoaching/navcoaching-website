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
