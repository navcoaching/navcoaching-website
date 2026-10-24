// مقياس الألم بعد التمرين (0–10) لمنطقة الشكوى المكتوبة. منطق خالص يُختبر مباشرة.
// الدرجات من نموذج مراقبة الألم المستخدم في تأهيل التهاب الأوتار (0–2 آمن، 3–5 مقبول إذا هدأ خلال 24 ساعة، أعلى من 5 كثير).

export const PAIN_ZONES = [
  { range: "0–2", tone: "ok", text: "لا ألم أو خفيف جداً: آمن، كمّل." },
  { range: "3–5", tone: "mid", text: "متوسط: مقبول إذا خفّ خلال 24 ساعة ورجع لمستواه بصباح اليوم التالي." },
  { range: "6–10", tone: "hi", text: "عالي: خفّف الوزن أو المدى، وإذا استمر أوقف التمرين وبلّغ المدربة." },
] as const;

/** لون الدرجة: أخضر 0–2، أصفر 3–5، أحمر 6–10 */
export const painTone = (n: number) => (n <= 2 ? "ok" : n <= 5 ? "mid" : "hi");

/** اسم المقياس من عنوان عمود الملف: «ألم الركبة 0–10» ← «ألم الركبة». بدون ذكر ألم ← null */
export function painLabelFrom(header: string): string | null {
  if (!/ألم|pain/i.test(header)) return null;
  const s = header.replace(/\([^)]*\)/g, " ").replace(/[0-9٠-٩]+\s*[–\-—~]\s*[0-9٠-٩]+|\d+|[/:：]/g, " ").replace(/\s+/g, " ").trim();
  return s.length >= 2 && s.length <= 40 ? s : "الألم";
}

// منطقة الشكوى ← العضلات اللي تحمّلها (من العضلة الأساسية للتمرين في المكتبة)
const REGIONS: [RegExp, RegExp][] = [
  [/ركب|knee/i, /quadriceps|hamstrings|glutes|adductors|abductors|calves/i],
  [/مرفق|كوع|elbow/i, /biceps|triceps|forearms/i],
  [/معصم|رسغ|wrist/i, /forearms|biceps|triceps|chest/i],
  [/كتف|shoulder/i, /shoulders|chest|back & lats|rotator/i],
  [/أسفل الظهر|الظهر|lower back|back/i, /lower back|hamstrings|glutes/i],
  [/ورك|حوض|hip/i, /glutes|adductors|abductors|quadriceps|hamstrings/i],
  [/كاحل|ankle/i, /calves|quadriceps/i],
];

/**
 * هل يُطبَّق المقياس على هذا التمرين؟ فقط إذا كانت عضلته الأساسية تحمّل منطقة الشكوى المكتوبة
 * (ألم الركبة ← تمارين الرجل، ألم المرفق ← تمارين الذراع). منطقة غير معروفة ← يُطبَّق كما في الملف.
 */
export function painApplies(label: string, primaryMuscle: string | null | undefined): boolean {
  const region = REGIONS.find(([re]) => re.test(label));
  if (!region) return true;
  return region[1].test(primaryMuscle ?? "");
}
