// استبيان الطلب في التطبيق: منطق خالص (تحقق كل خطوة، وتجهيز الإرسال) بنفس قواعد الموقع (src/lib/intake.ts).
// التحقق هنا لتجربة أسرع فقط؛ الحكم النهائي في الخادم، وأخطاؤه ترجع لنفس الحقول.

export type CustomQ = { id: string; step: number; type: "text" | "long" | "choice" | "yesno"; label: string; hint: string; options: string[]; required: boolean };
export type CheckoutData = {
  sku: string;
  offers: { sku: string; product: string; label: string; group: string; price_halalas: number }[];
  defaultName: string; email: string; responseTime: string;
  opt: Record<string, string[]>; ageMin: number; ageMax: number; nutritionSkus: string[];
  questions: Record<string, { label: string; hint: string; hidden: boolean }>;
  custom: CustomQ[];
  startRange: { min: string; max: string };
};
export type Answers = Record<string, string | string[]>;

export const STEP_TITLES = ["الباقة والتواصل", "الهدف والتمرين", "الصحة والإصابات", "القياسات ونمط الحياة", "التوقعات والإرسال"];
export const STEP_OF: Record<string, number> = {
  sku: 1, name: 1, cc: 1, phone: 1, gender: 1, age: 1, guardian_ok: 1, city: 1, student: 1,
  goal: 2, level: 2, place: 2, equip: 2, days: 2, duration: 2,
  injury: 3, condition: 3, pregnancy: 3, health_notes: 3, health_ack: 3,
  weight: 4, height: 4, bodyfat: 4, steps: 4, sleep: 4, job: 4, calories: 4,
};
/** البيانات الصحية والقياسات لا تُحفظ في المسودة على الجهاز (كما في الموقع) */
export const SENSITIVE = new Set(["injury", "condition", "pregnancy", "health_notes", "health_ack", "weight", "height", "bodyfat"]);
export const customField = (id: string) => `cq_${id}`;

/** الأرقام العربية والفاصلة العربية إلى صيغة يفهمها الخادم */
export const latin = (s: string) => s.replace(/[٠-٩]/g, (c) => String(c.charCodeAt(0) - 0x0660)).replace(/[٫,]/g, ".").trim();

export const str = (a: Answers, k: string) => (typeof a[k] === "string" ? (a[k] as string) : "");
export const isFemale = (a: Answers) => str(a, "gender") === "أنثى";
export const atHome = (a: Answers) => ["البيت", "كلاهما"].includes(str(a, "place"));
export const healthYes = (a: Answers) =>
  str(a, "injury") === "نعم" || str(a, "condition") === "نعم" || (isFemale(a) && ["حامل", "بعد الولادة"].includes(str(a, "pregnancy")));
export const needsCalories = (a: Answers, d: CheckoutData) => d.nutritionSkus.includes(str(a, "sku") || d.sku);
export const stepOf = (key: string, d: CheckoutData) => STEP_OF[key] ?? d.custom.find((c) => customField(c.id) === key)?.step ?? 5;

export function validateStep(n: number, a: Answers, d: CheckoutData): Record<string, string> {
  const e: Record<string, string> = {};
  const s = (k: string) => str(a, k).trim();
  const need = (k: string, msg: string) => { if (!s(k)) e[k] = msg; };
  if (n === 1) {
    need("sku", "اختر الباقة");
    if (s("name").length < 2) e.name = "اكتب اسمك (حرفين على الأقل).";
    const sa = (s("cc") || "+966") === "+966";
    const digits = latin(s("phone")).replace(/[^\d]/g, "").replace(/^0+/, "");
    if (sa ? !/^5\d{8}$/.test(digits) : !/^\d{6,14}$/.test(digits))
      e.phone = sa ? "الرقم السعودي يبدأ بـ 5 ويتكون من 9 أرقام، مثل 512345678." : "اكتب رقماً صحيحاً.";
    need("gender", "اختر الجنس — نحتاجه لتصميم البرنامج والمراجع المناسبة.");
    const age = latin(s("age"));
    const ageOk = /^\d{1,3}$/.test(age) && Number(age) >= d.ageMin && Number(age) <= d.ageMax;
    if (!ageOk) e.age = `اكتب عمرك رقماً صحيحاً بين ${d.ageMin} و ${d.ageMax}.`;
    else if (Number(age) < 18 && s("guardian_ok") !== "on") e.guardian_ok = "للأعمار أقل من 18 نحتاج تأكيد موافقة ولي الأمر.";
  } else if (n === 2) {
    need("goal", "اختر هدفاً واحداً — الأقرب لك الآن.");
    need("level", "اختر مستواك.");
    need("place", "اختر مكان التمرين.");
    need("days", "اختر عدد الأيام.");
    need("duration", "اختر الوقت المتاح.");
  } else if (n === 3) {
    need("injury", "اختر نعم أو لا.");
    need("condition", "اختر نعم أو لا.");
    if (s("health_ack") !== "on") e.health_ack = "نحتاج موافقتك على هذه النقطة للمتابعة.";
  } else if (n === 4) {
    const w = Number(latin(s("weight"))), h = Number(latin(s("height")));
    if (!s("weight") || !(w >= 30 && w <= 250)) e.weight = "اكتب وزناً بين 30 و 250 كغ.";
    if (!s("height") || !(h >= 120 && h <= 230)) e.height = "اكتب طولاً بين 120 و 230 سم.";
    if (needsCalories(a, d)) need("calories", "اختر خبرتك — باقتك تشمل تغذية.");
  } else if (n === 5) {
    if (s("expectations").length < 3) e.expectations = "هذا السؤال مطلوب.";
    if (s("start_mode") === "date" && !s("start_date")) e.start_date = "اختر تاريخ البداية.";
    need("media", "اختر إجابة.");
    if (s("consent_terms") !== "on") e.consent_terms = "نحتاج موافقتك للإرسال.";
    if (s("consent_wa") !== "on") e.consent_wa = "التواصل يتم على واتساب، فنحتاج موافقتك.";
  }
  for (const q of d.custom) if (q.step === n && q.required && !s(customField(q.id))) e[customField(q.id)] = "هذا السؤال مطلوب.";
  return e;
}

/** حقول الإرسال بنفس أسماء نموذج الموقع؛ الحقول غير المنطبقة (مثل الحمل لغير الإناث) تُفرغ */
export function toFields(a: Answers): [string, string][] {
  const out: [string, string][] = [];
  const skip = new Set<string>();
  if (!isFemale(a)) skip.add("pregnancy");
  if (!atHome(a)) skip.add("equip");
  if (!healthYes(a)) skip.add("health_notes");
  if (str(a, "prev_coach") !== "نعم") skip.add("prev_why");
  if (str(a, "start_mode") !== "date") skip.add("start_date");
  for (const [k, v] of Object.entries(a)) {
    if (skip.has(k)) continue;
    if (Array.isArray(v)) for (const x of v) out.push([k, x]);
    else if (v !== "") out.push([k, ["age", "weight", "height", "phone"].includes(k) ? latin(v) : v]);
  }
  if (!a.cc) out.push(["cc", "+966"]);
  return out;
}
