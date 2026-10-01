// أسئلة الاستبيان القابلة للتعديل من لوحة الإدارة (المحتوى والإعدادات ← أسئلة الاستبيان). منطق خالص بدون واجهة ولا قاعدة بيانات.
// - الأسئلة الأساسية: تعديل نص السؤال وتلميح تحته، وإخفاء الاختياري منها. الخيارات ثابتة لأن حساب السعرات والبيانات الصحية مبنيان عليها.
// - أسئلة إضافية: نص قصير، نص طويل، اختيار من قائمة، أو نعم/لا، في الخطوة اللي تختارها، وإجاباتها تُحفظ مع الطلب وتظهر للمدربة.
import { EXPECTATIONS_Q } from "./intake.ts";

export const STEP_TITLES = ["الباقة والتواصل", "الهدف والتمرين", "الصحة والإصابات", "القياسات ونمط الحياة", "التوقعات والإرسال"] as const;

export type BuiltinQuestion = { key: string; label: string; step: 1 | 2 | 3 | 4 | 5; hideable?: boolean };
/** الأسئلة الأساسية بنصوصها الافتراضية (ما عدا الموافقات والباقة ورمز الدولة، فهذي ثابتة) */
export const BUILTIN_QUESTIONS: BuiltinQuestion[] = [
  { key: "name", label: "الاسم", step: 1 }, { key: "phone", label: "رقم واتساب", step: 1 },
  { key: "gender", label: "الجنس", step: 1 }, { key: "age", label: "العمر", step: 1 },
  { key: "city", label: "المدينة (اختياري)", step: 1, hideable: true },
  { key: "goal", label: "هدفك الرئيسي", step: 2 }, { key: "level", label: "مستواك", step: 2 }, { key: "place", label: "مكان التمرين", step: 2 },
  { key: "equip", label: "الأدوات المتوفرة في البيت (اختر كل ما ينطبق)", step: 2 },
  { key: "days", label: "أيام التمرين بالأسبوع", step: 2 }, { key: "duration", label: "وقت التمرين باليوم", step: 2 },
  { key: "injury", label: "هل عندك إصابة حالية أو ألم يحد من التمرين؟", step: 3 },
  { key: "condition", label: "هل عندك حالة صحية أو تعليمات طبية قد تؤثر على التمرين؟", step: 3 },
  { key: "pregnancy", label: "هل أنتِ حامل أو في السنة الأولى بعد الولادة؟ (اختياري)", step: 3 },
  { key: "health_notes", label: "وضّح باختصار (مثال: ألم أسفل الظهر مع الانحناء)", step: 3 },
  { key: "weight", label: "الوزن الحالي (كغ)", step: 4 }, { key: "height", label: "الطول (سم)", step: 4 },
  { key: "bodyfat", label: "نسبة الدهون التقريبية (اختياري)", step: 4, hideable: true },
  { key: "steps", label: "خطواتك اليومية", step: 4 },
  { key: "sleep", label: "ساعات النوم", step: 4, hideable: true },
  { key: "job", label: "طبيعة يومك (اختياري)", step: 4, hideable: true },
  { key: "calories", label: "خبرتك في حساب السعرات", step: 4 },
  { key: "expectations", label: EXPECTATIONS_Q, step: 5 },
  { key: "challenge", label: "وش أكبر تحدي تواجهه الآن؟ (اختياري)", step: 5, hideable: true },
  { key: "prev_coach", label: "تدربت مع مدرب قبل؟", step: 5, hideable: true },
  { key: "prev_why", label: "ليه ما استمريت معه؟ (اختياري)", step: 5 },
  { key: "source", label: "من وين سمعت عني؟", step: 5, hideable: true },
  { key: "media", label: "هل تسمح بعرض نتيجتك في السوشل ميديا؟", step: 5 },
  { key: "notes", label: "أي شي تبي تضيفه؟ (اختياري)", step: 5, hideable: true },
];
const BUILTIN = new Map(BUILTIN_QUESTIONS.map((q) => [q.key, q]));

export const CUSTOM_TYPES = [
  { v: "text", l: "نص قصير" }, { v: "long", l: "نص طويل" }, { v: "choice", l: "اختيار من قائمة" }, { v: "yesno", l: "نعم / لا" },
] as const;
export type CustomType = (typeof CUSTOM_TYPES)[number]["v"];
export type CustomQuestion = { id: string; step: 1 | 2 | 3 | 4 | 5; type: CustomType; label: string; hint: string; options: string[]; required: boolean; active: boolean };
export type IntakeConfig = { labels: Record<string, { label?: string; hint?: string; hidden?: boolean }>; custom: CustomQuestion[] };

export const EMPTY_CONFIG: IntakeConfig = { labels: {}, custom: [] };
export const LIMITS = { label: 160, hint: 240, option: 60, options: 10, custom: 12, text: 300, long: 1000 } as const;
export const customField = (id: string) => `cq_${id}`;

const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");
const step = (v: unknown): 1 | 2 | 3 | 4 | 5 => { const n = Number(v); return n >= 1 && n <= 5 && Number.isInteger(n) ? (n as 1 | 2 | 3 | 4 | 5) : 5; };

/** يقرأ الإعداد المحفوظ بأمان (أي قيمة غير صالحة تُتجاهل) */
export function parseConfig(raw: unknown): IntakeConfig {
  const r = (raw && typeof raw === "object" ? raw : {}) as { labels?: unknown; custom?: unknown };
  const labels: IntakeConfig["labels"] = {};
  if (r.labels && typeof r.labels === "object") {
    for (const [k, val] of Object.entries(r.labels as Record<string, Record<string, unknown>>)) {
      const q = BUILTIN.get(k);
      if (!q || !val || typeof val !== "object") continue;
      const label = str(val.label, LIMITS.label), hint = str(val.hint, LIMITS.hint);
      const hidden = q.hideable === true && val.hidden === true;
      if (label || hint || hidden) labels[k] = { ...(label ? { label } : {}), ...(hint ? { hint } : {}), ...(hidden ? { hidden } : {}) };
    }
  }
  const custom: CustomQuestion[] = [];
  if (Array.isArray(r.custom)) {
    for (const c of r.custom.slice(0, LIMITS.custom) as Record<string, unknown>[]) {
      const id = str(c?.id, 16);
      const type = CUSTOM_TYPES.find((t) => t.v === c?.type)?.v;
      const label = str(c?.label, LIMITS.label);
      if (!/^[a-z0-9]{4,16}$/.test(id) || !type || !label || custom.some((x) => x.id === id)) continue;
      const options = type === "choice" && Array.isArray(c.options) ? (c.options as unknown[]).map((o) => str(o, LIMITS.option)).filter(Boolean).slice(0, LIMITS.options) : [];
      if (type === "choice" && options.length < 2) continue;
      custom.push({ id, step: step(c.step), type, label, hint: str(c.hint, LIMITS.hint), options, required: c.required === true, active: c.active !== false });
    }
  }
  return { labels, custom };
}

export const labelOf = (cfg: IntakeConfig, key: string) => cfg.labels[key]?.label || BUILTIN.get(key)?.label || key;
export const hintOf = (cfg: IntakeConfig, key: string) => cfg.labels[key]?.hint ?? "";
/** سؤال مخفي: فقط الاختياري القابل للإخفاء. prev_why يتبع prev_coach */
export const isHidden = (cfg: IntakeConfig, key: string) =>
  key === "prev_why" ? cfg.labels.prev_coach?.hidden === true : cfg.labels[key]?.hidden === true && BUILTIN.get(key)?.hideable === true;
export const activeCustom = (cfg: IntakeConfig, s?: number) => cfg.custom.filter((c) => c.active && (s == null || c.step === s));

type Getter = (name: string) => string;
export type CustomAnswer = { id: string; label: string; value: string };

/** يتحقق من إجابات الأسئلة الإضافية النشطة ويرجع الإجابات (بنص السؤال وقت الإرسال) أو أخطاء لكل حقل */
export function validateCustomAnswers(cfg: IntakeConfig, get: Getter): { answers: CustomAnswer[]; errors: Record<string, string> } {
  const answers: CustomAnswer[] = [], errors: Record<string, string> = {};
  for (const q of activeCustom(cfg)) {
    const name = customField(q.id);
    const raw = get(name).trim();
    if (!raw) { if (q.required) errors[name] = "هذا السؤال مطلوب."; continue; }
    const max = q.type === "long" ? LIMITS.long : LIMITS.text;
    if (q.type === "choice" && !q.options.includes(raw)) { errors[name] = "اختيار غير صالح."; continue; }
    if (q.type === "yesno" && !["نعم", "لا"].includes(raw)) { errors[name] = "اختر نعم أو لا."; continue; }
    if ((q.type === "text" || q.type === "long") && raw.length > max) { errors[name] = `النص أطول من ${max} حرفاً.`; continue; }
    answers.push({ id: q.id, label: q.label, value: raw });
  }
  return { answers, errors };
}

/** يبني الإعداد من نموذج لوحة الإدارة: l_<key>, h_<key>, x_<key> للأساسية، و c<i>_* للإضافية (السؤال بدون نص يُحذف) */
export function configFromForm(get: Getter, oldIds: string[] = []): { config: IntakeConfig } | { error: string } {
  const labels: IntakeConfig["labels"] = {};
  for (const q of BUILTIN_QUESTIONS) {
    const label = get(`l_${q.key}`).trim(), hint = get(`h_${q.key}`).trim(), hidden = q.hideable === true && get(`x_${q.key}`) === "on";
    if (label.length > LIMITS.label) return { error: `نص «${q.label}» أطول من ${LIMITS.label} حرفاً.` };
    if (hint.length > LIMITS.hint) return { error: `التلميح تحت «${q.label}» أطول من ${LIMITS.hint} حرفاً.` };
    // النص المطابق للأصلي لا يُحفظ (حتى يتبع أي تغيير مستقبلي في النص الافتراضي)
    const l = label && label !== q.label ? label : "";
    if (l || hint || hidden) labels[q.key] = { ...(l ? { label: l } : {}), ...(hint ? { hint } : {}), ...(hidden ? { hidden } : {}) };
  }
  const custom: CustomQuestion[] = [];
  for (let i = 0; i < LIMITS.custom; i++) {
    const label = get(`c${i}_label`).trim();
    if (!label) continue;
    const type = CUSTOM_TYPES.find((t) => t.v === get(`c${i}_type`))?.v;
    if (!type) return { error: `اختاري نوع السؤال «${label}».` };
    if (label.length > LIMITS.label) return { error: `نص السؤال «${label.slice(0, 30)}…» أطول من ${LIMITS.label} حرفاً.` };
    const options = get(`c${i}_options`).split("\n").map((o) => o.trim()).filter(Boolean);
    if (type === "choice") {
      if (options.length < 2) return { error: `السؤال «${label}» يحتاج خيارين على الأقل (خيار في كل سطر).` };
      if (options.length > LIMITS.options || options.some((o) => o.length > LIMITS.option)) return { error: `خيارات «${label}»: حتى ${LIMITS.options} خيارات، وكل خيار حتى ${LIMITS.option} حرفاً.` };
    }
    let id = get(`c${i}_id`).trim();
    if (!/^[a-z0-9]{4,16}$/.test(id) || custom.some((c) => c.id === id)) id = newId(oldIds.concat(custom.map((c) => c.id)));
    custom.push({ id, step: step(get(`c${i}_step`)), type, label, hint: get(`c${i}_hint`).trim().slice(0, LIMITS.hint), options: type === "choice" ? options : [],
      required: get(`c${i}_req`) === "on", active: get(`c${i}_active`) === "on" });
  }
  return { config: { labels, custom } };
}

function newId(used: string[]) {
  const abc = "abcdefghjkmnpqrstuvwxyz23456789";
  for (;;) {
    const id = "q" + Array.from({ length: 6 }, () => abc[Math.floor(Math.random() * abc.length)]).join("");
    if (!used.includes(id)) return id;
  }
}
