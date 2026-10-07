// منطق المتتبّع الصافي (بدون واجهة ولا قاعدة بيانات) حتى يُختبر مباشرة بـ node --test.

export type SetKind = "warmup" | "normal" | "drop";

/** أقصى وزن تقديري لتكرار واحد (معادلة Epley). جولات الإحماء لا تُحسب في الأرقام القياسية. */
export function e1rm(weight: number, reps: number): number {
  if (!(weight > 0) || !(reps > 0)) return 0;
  if (reps === 1) return weight;
  return Math.round(weight * (1 + reps / 30) * 10) / 10;
}

/** هدف التكرارات كما تكتبه المدربة: "10" أو "8-12" */
export function parseReps(target: string | null | undefined): { min: number; max: number } | null {
  const m = /^\s*(\d{1,3})\s*(?:[-–]\s*(\d{1,3}))?\s*$/.exec(target ?? "");
  if (!m) return null;
  const a = Number(m[1]);
  const b = m[2] ? Number(m[2]) : a;
  if (a < 1 || b < a) return null;
  return { min: a, max: b };
}

/** وزن بدون أصفار زائدة: 40 ← "40"، 42.5 ← "42.5" */
export function formatKg(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return "";
  return String(Math.round(n * 100) / 100);
}

/** يقرأ رقماً كتبه المستخدم (يقبل الأرقام العربية والفاصلة العربية). يرجع null للفارغ أو غير الصالح. */
export function parseNumber(input: string, opts: { max: number; integer?: boolean }): number | null {
  const ascii = input
    .trim()
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
    .replace(/[٫,]/g, ".");
  if (ascii === "" || !/^\d+(\.\d+)?$/.test(ascii)) return null;
  const n = Number(ascii);
  if (n > opts.max) return null;
  if (opts.integer && !Number.isInteger(n)) return null;
  return n;
}

export type DoneSet = { exerciseId: string; kind: SetKind; weight: number; reps: number };

/** الحجم التدريبي (الوزن × التكرارات) للجولات المكتملة، بدون الإحماء */
export function volume(sets: DoneSet[]): number {
  return Math.round(sets.reduce((s, x) => (x.kind === "warmup" ? s : s + x.weight * x.reps), 0));
}

export type Record = { exerciseId: string; type: "e1rm" | "weight"; value: number; previous: number | null };

/**
 * الأرقام القياسية الجديدة في هذا التمرين مقارنة بأفضل ما سبق.
 * أول مرة يُسجَّل فيها التمرين لا تُعد رقماً قياسياً (لا يوجد ما يُقارن به، وإلا صار كل شيء رقماً قياسياً).
 */
export function newRecords(current: DoneSet[], best: Map<string, { e1rm: number; weight: number }>): Record[] {
  const byEx = new Map<string, { e1rm: number; weight: number }>();
  for (const s of current) {
    if (s.kind === "warmup" || !(s.reps > 0) || !(s.weight > 0)) continue;
    const cur = byEx.get(s.exerciseId) ?? { e1rm: 0, weight: 0 };
    byEx.set(s.exerciseId, { e1rm: Math.max(cur.e1rm, e1rm(s.weight, s.reps)), weight: Math.max(cur.weight, s.weight) });
  }
  const out: Record[] = [];
  for (const [exerciseId, cur] of byEx) {
    const prev = best.get(exerciseId);
    if (!prev) continue;
    if (cur.e1rm > prev.e1rm) out.push({ exerciseId, type: "e1rm", value: cur.e1rm, previous: prev.e1rm });
    if (cur.weight > prev.weight) out.push({ exerciseId, type: "weight", value: cur.weight, previous: prev.weight });
  }
  return out;
}

/** مدة بصيغة مختصرة: 1:05:09 أو 45:09 */
export function formatDuration(totalSec: number): string {
  const s = Math.max(0, Math.floor(totalSec));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}
