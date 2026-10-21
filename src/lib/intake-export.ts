import { ANSWER_LABELS, EXPECTATIONS_Q } from "./intake.ts";

// تصدير «الاستبيان» ملف Markdown: عناوين وأسئلة بنصها وإجابة بجانب كل سؤال، يقرؤه الإنسان والذكاء الاصطناعي بسهولة.
// بدون رقم الجوال والبريد عمداً: الملف للبرنامج لا للتواصل، وقد يُرفع لأداة خارجية.

type Intake = { answers: Record<string, unknown>; health: Record<string, unknown>; health_flag: boolean; media_consent: string; created_at: string | Date };
type Order = { order_no: string; product_name: string; offer_label?: string | null; user_name?: string | null; contact_name?: string | null; student_discount_requested?: boolean | null; client_note?: string | null };

const SKIP = new Set(["expectations", "age", "custom"]);
// سطر واحد لكل إجابة: الأسطر الجديدة داخل النص تصير فاصلاً
const one = (v: unknown) => (Array.isArray(v) ? v.join("، ") : v == null || v === "" ? "—" : String(v)).replace(/\s*\n+\s*/g, " / ");
const quote = (v: unknown) => (v == null || v === "" ? "> —" : String(v).trim().split(/\r?\n/).map((l) => `> ${l}`).join("\n"));
const line = (label: string, v: unknown) => `- **${label}:** ${one(v)}`;
const day = (d: string | Date) => new Date(d).toISOString().slice(0, 10);
// قسم بلا إجابات يظهر «—» بدل فراغ حتى لا يبدو الملف ناقصاً
const orNone = (lines: string[]) => (lines.length ? lines : ["- —"]);

export function intakeMarkdown(o: Order, i: Intake): string {
  const a = i.answers, h = i.health;
  const age = typeof a.age === "number" ? `${a.age} سنة` : a.age;
  const custom = Array.isArray(a.custom) ? (a.custom as { label: string; value: string }[]) : [];
  const out = [
    `# استبيان المتدرب: ${o.order_no}`,
    "",
    line("الاسم", o.contact_name || o.user_name),
    line("الباقة", [o.product_name, o.offer_label].filter(Boolean).join(" · ")),
    line("تاريخ الاستبيان", day(i.created_at)),
    "",
    `## ${EXPECTATIONS_Q}`,
    "",
    quote(a.expectations),
    "",
    "## الأساسيات",
    "",
    line("العمر", age),
    line("الوزن (كغ)", h.weight),
    line("الطول (سم)", h.height),
    "",
    "## الإجابات",
    "",
    ...orNone([
      ...Object.entries(a).filter(([k]) => !SKIP.has(k)).map(([k, v]) => line(ANSWER_LABELS[k] ?? k, v)),
      ...custom.map((c) => line(c.label, c.value)),
    ]),
    "",
    `## البيانات الصحية (سرية)${i.health_flag ? " — تحتاج مراعاة" : ""}`,
    "",
    ...orNone(Object.entries(h).filter(([k]) => k !== "weight" && k !== "height").map(([k, v]) => line(ANSWER_LABELS[k] ?? k, v))),
    "",
    "## الطلب",
    "",
    line("النشر في السوشل ميديا", i.media_consent),
    line("طلب خصم طالب", o.student_discount_requested ? "نعم" : "لا"),
    line("ملاحظة العميل", o.client_note),
    "",
  ];
  return out.join("\n");
}
