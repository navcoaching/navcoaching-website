import { z } from "zod";
import { validStartPref } from "./schedule.ts";

// «الاستبيان»: نموذج التسجيل الأولي للمتدرب (كان اسمه «تقييم المتدرب» في الموقع السابق).
// الأسماء الداخلية القديمة باقية كما هي حتى لا ينكسر ترابط البيانات: الجدول intakes والدالة create_order = الاستبيان.
// لا علاقة له بـ reviews (تقييمات الخدمة بعد التجربة المنشورة للزوار).
// الخيارات منقولة من نموذج الموقع السابق (assessment.html).
export const OPT = {
  cc: ["+966", "+971", "+965", "+973", "+974", "+968", "أخرى"],
  gender: ["أنثى", "ذكر"],
  city: ["الدمام", "الخبر", "الظهران", "الرياض", "جدة", "مدينة أخرى في السعودية", "خارج السعودية"],
  goal: ["نزول دهون", "بناء عضل", "نزول دهون + بناء عضل", "زيادة وزن", "لياقة وقوة", "أداء رياضي", "أخرى"],
  level: ["مبتدئ · أقل من 6 أشهر", "متوسط · 6 أشهر – سنتين", "متقدم · أكثر من سنتين"],
  place: ["نادي", "البيت", "كلاهما"],
  equip: ["دمبلز", "حبال مقاومة", "شنطة أوزان 20 كغ+", "بار عقلة", "بنش", "جهاز كارديو", "لا شيء"],
  days: ["2 أيام", "3 أيام", "4 أيام", "5 أيام", "6 أيام"],
  duration: ["أقل من ساعة", "ساعة", "ساعة ونص", "ساعتين أو أكثر"],
  yesno: ["لا", "نعم"],
  pregnancy: ["لا", "حامل", "بعد الولادة"],
  bodyfat_male: ["8 – 11%", "12 – 15%", "16 – 19%", "20 – 24%", "25 – 29%", "30% فأكثر", "لا أعرف"],
  bodyfat_female: ["15 – 19%", "20 – 24%", "25 – 29%", "30 – 34%", "35 – 39%", "40% فأكثر", "لا أعرف"],
  steps: ["أقل من 3,000", "3,000 – 6,000", "6,000 – 10,000", "أكثر من 10,000", "لا أعرف"],
  sleep: ["أقل من 5", "5 – 6", "7 – 8", "أكثر من 8"],
  job: ["عمل مكتبي", "عمل ميداني / حركة كثيرة", "دوام بنظام الورديات", "طالب", "في البيت", "أخرى"],
  calories: ["لا توجد خلفية", "أعرف الأساسيات", "أحسب سعراتي بانتظام"],
  source: ["انستقرام", "سناب شات", "تويتر (X)", "صديق", "متدرب عندي", "النادي", "أخرى"],
  media: ["نعم", "نعم، بشرط إخفاء الوجه", "لا، أفضّل الخصوصية"],
} as const;

/** العروض التي تشمل تغذية (خبرة السعرات إلزامية فيها) — من الموقع الحالي */
/** حدود العمر المقبولة في الاستبيان (عدّليها هنا عند الحاجة) */
export const AGE_MIN = 10;
export const AGE_MAX = 90;
/** نص السؤال كما طلبته المدربة حرفياً */
export const EXPECTATIONS_Q = "ماذا تتوقع مني أثناء التدريب؟";

export const NUTRITION_SKUS = ["int1", "int3", "adv1", "adv3", "nut1", "diyN", "cN"];

const oneOf = <T extends readonly string[]>(list: T, msg: string) => z.enum(list as unknown as [string, ...string[]], { message: msg });
const optionalOneOf = <T extends readonly string[]>(list: T) => z.union([z.literal(""), oneOf(list, "اختيار غير صالح")]).optional().default("");
const text = (max: number) => z.string().trim().max(max, `النص أطول من ${max} حرفاً`).optional().default("");

export const intakeSchema = z
  .object({
    idempotency_key: z.string().min(16).max(80),
    sku: z.string().min(1).max(40),
    name: z.string().trim().min(2, "اكتب اسمك (حرفين على الأقل).").max(80),
    cc: oneOf(OPT.cc, "اختر رمز الدولة"),
    phone: z.string().trim().max(20),
    gender: oneOf(OPT.gender, "اختر الجنس"),
    age: z.string().trim().regex(/^\d{1,3}$/, `اكتب عمرك رقماً صحيحاً بين ${AGE_MIN} و ${AGE_MAX}.`)
      .transform(Number).refine((n) => n >= AGE_MIN && n <= AGE_MAX, `اكتب عمرك رقماً صحيحاً بين ${AGE_MIN} و ${AGE_MAX}.`),
    guardian_ok: z.enum(["", "on"]).optional().default(""),
    city: optionalOneOf(OPT.city),
    student: z.enum(["", "نعم"]).optional().default(""),
    goal: oneOf(OPT.goal, "اختر هدفاً"),
    level: oneOf(OPT.level, "اختر مستواك"),
    place: oneOf(OPT.place, "اختر مكان التمرين"),
    equip: z.array(oneOf(OPT.equip, "اختيار غير صالح")).max(OPT.equip.length).default([]),
    days: oneOf(OPT.days, "اختر عدد الأيام"),
    duration: oneOf(OPT.duration, "اختر الوقت المتاح"),
    injury: oneOf(OPT.yesno, "اختر نعم أو لا"),
    condition: oneOf(OPT.yesno, "اختر نعم أو لا"),
    pregnancy: optionalOneOf(OPT.pregnancy),
    health_notes: text(600),
    health_ack: z.literal("on", { message: "نحتاج موافقتك على هذه النقطة للمتابعة." }),
    weight: z.coerce.number({ message: "اكتب وزنك بالكيلوغرام." }).min(30, "اكتب وزناً بين 30 و 250 كغ.").max(250, "اكتب وزناً بين 30 و 250 كغ."),
    height: z.coerce.number({ message: "اكتب طولك بالسنتيمتر." }).min(120, "اكتب طولاً بين 120 و 230 سم.").max(230, "اكتب طولاً بين 120 و 230 سم."),
    bodyfat: optionalOneOf([...new Set([...OPT.bodyfat_male, ...OPT.bodyfat_female])]),
    steps: optionalOneOf(OPT.steps),
    sleep: optionalOneOf(OPT.sleep),
    job: optionalOneOf(OPT.job),
    calories: optionalOneOf(OPT.calories),
    expectations: z.string().trim().min(3, "هذا السؤال مطلوب.").max(1000, "النص أطول من 1000 حرف."),
    challenge: text(600),
    prev_coach: optionalOneOf(OPT.yesno),
    prev_why: text(300),
    source: optionalOneOf(OPT.source),
    media: oneOf(OPT.media, "اختر إجابة"),
    notes: text(800),
    start_mode: z.enum(["asap", "date"], { message: "اختر متى تبي تبدأ." }).optional().default("asap"),
    start_date: z.string().trim().max(10).optional().default(""),
    consent_terms: z.literal("on", { message: "نحتاج موافقتك للإرسال." }),
    consent_wa: z.literal("on", { message: "التواصل يتم على واتساب، فنحتاج موافقتك." }),
    website: z.string().max(0, "spam").optional().default(""), // honeypot
  })
  .superRefine((v, ctx) => {
    if (v.start_mode === "date" && !validStartPref(v.start_date))
      ctx.addIssue({ code: "custom", path: ["start_date"], message: "اختر تاريخاً من بكرة إلى شهر من اليوم." });
    if (v.age < 18 && v.guardian_ok !== "on")
      ctx.addIssue({ code: "custom", path: ["guardian_ok"], message: "للأعمار أقل من 18 نحتاج تأكيد موافقة ولي الأمر." });
    if (NUTRITION_SKUS.includes(v.sku) && !v.calories)
      ctx.addIssue({ code: "custom", path: ["calories"], message: "اختر خبرتك — باقتك تشمل تغذية." });
    const digits = v.phone.replace(/[^\d]/g, "").replace(/^0+/, "");
    if (v.cc === "+966" ? !/^5\d{8}$/.test(digits) : !/^\d{6,14}$/.test(digits))
      ctx.addIssue({ code: "custom", path: ["phone"], message: v.cc === "+966" ? "الرقم السعودي يبدأ بـ 5 ويتكون من 9 أرقام، مثل 512345678." : "اكتب رقماً صحيحاً." });
  });

export type IntakeInput = z.infer<typeof intakeSchema>;

export function normalizedPhone(cc: string, phone: string) {
  const digits = phone.replace(/[^\d]/g, "").replace(/^0+/, "");
  return cc === "أخرى" ? `+${digits}` : `${cc}${digits}`;
}

/** يفصل الإجابات العامة عن البيانات الصحية (تُحفظ في عمود منفصل ولا تُرسل في أي تنبيه). */
export function splitIntake(v: IntakeInput) {
  const health = {
    injury: v.injury, condition: v.condition, pregnancy: v.pregnancy, health_notes: v.health_notes,
    weight: v.weight, height: v.height, bodyfat: v.bodyfat,
  };
  const answers = {
    gender: v.gender, age: v.age, city: v.city, goal: v.goal, level: v.level, place: v.place, equip: v.equip,
    days: v.days, duration: v.duration, steps: v.steps, sleep: v.sleep, job: v.job, calories: v.calories,
    expectations: v.expectations, guardian_ok: v.age < 18 ? "نعم" : "",
    challenge: v.challenge, prev_coach: v.prev_coach, prev_why: v.prev_why, source: v.source, notes: v.notes,
  };
  const healthFlag = v.injury === "نعم" || v.condition === "نعم" || ["حامل", "بعد الولادة"].includes(v.pregnancy);
  return { answers, health, healthFlag };
}

export const ANSWER_LABELS: Record<string, string> = {
  expectations: EXPECTATIONS_Q, guardian_ok: "موافقة ولي الأمر",
  gender: "الجنس", age: "العمر", city: "المدينة", goal: "الهدف", level: "المستوى", place: "مكان التمرين",
  equip: "الأدوات", days: "أيام التمرين", duration: "الوقت باليوم", steps: "الخطوات اليومية", sleep: "ساعات النوم",
  job: "طبيعة اليوم", calories: "خبرة السعرات", challenge: "أكبر تحدي", prev_coach: "تدرب مع مدرب قبل",
  prev_why: "سبب عدم الاستمرار", source: "من وين سمع عنا", notes: "إضافات",
  injury: "إصابة حالية", condition: "حالة صحية", pregnancy: "حمل / بعد الولادة", health_notes: "ملاحظات صحية",
  weight: "الوزن (كغ)", height: "الطول (سم)", bodyfat: "نسبة الدهون",
};
