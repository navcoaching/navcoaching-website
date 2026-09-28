// السعرات المقترحة للمتدرب: نفس حاسبة Henselmans في الموقع (calories.ts) بآخر بيانات المتدرب.
// منطق خالص بدون قاعدة بيانات. الاقتراح لا يغيّر شيئاً؛ المدربة تعتمده أو تتجاهله.
import { EB_GOALS, PAF_LEVELS, calculateIntake, type BmrMethod } from "./calories.ts";

export type CalorieProfile = {
  method: BmrMethod; sex: "male" | "female" | null; age: number | null; height_cm: number | null; body_fat: number | null;
  paf: number; training_days: number; minutes: number; eb_factor: number; dismissed_kcal?: number | null;
};
export type Target = { kcal: number | null; protein: number | null; carbs: number | null; fat: number | null };
export type Suggestion = {
  kcal: number; protein: number | null; carbs: number | null; fat: number | null;
  diff: number | null; lowCarb: boolean; weight: number; weightSource: "logs" | "intake";
};

const DAYS: Record<string, number> = { "2 أيام": 2, "3 أيام": 3, "4 أيام": 4, "5 أيام": 5, "6 أيام": 6 };
const MINUTES: Record<string, number> = { "أقل من ساعة": 45, "ساعة": 60, "ساعة ونص": 90, "ساعتين أو أكثر": 120 };
const STEPS_PAF: Record<string, number> = { "أقل من 3,000": 1.0, "3,000 – 6,000": 1.1, "6,000 – 10,000": 1.2, "أكثر من 10,000": 1.3, "لا أعرف": 1.1 };
const GOAL_EB: Record<string, number> = { "نزول دهون": 0.8, "نزول دهون + بناء عضل": 0.9, "بناء عضل": 1.05, "زيادة وزن": 1.1 };

/** ملف الحساب الأولي من الاستبيان (المدربة تقدر تعدّل كل قيمة) */
export function profileFromIntake(answers: Record<string, unknown> | null | undefined, health: Record<string, unknown> | null | undefined): CalorieProfile {
  const a = answers ?? {}, h = health ?? {};
  const age = Number(a.age), height = Number(h.height);
  return {
    method: "tenhaaf",
    sex: a.gender === "ذكر" ? "male" : a.gender === "أنثى" ? "female" : null,
    age: Number.isFinite(age) && age > 0 ? age : null,
    height_cm: Number.isFinite(height) && height > 0 ? height : null,
    body_fat: null,
    paf: STEPS_PAF[String(a.steps ?? "")] ?? 1.1,
    training_days: DAYS[String(a.days ?? "")] ?? 3,
    minutes: MINUTES[String(a.duration ?? "")] ?? 60,
    eb_factor: GOAL_EB[String(a.goal ?? "")] ?? 1,
  };
}

/** الوزن الحالي: متوسط آخر 7 أيام من سجل الوزن (من آخر تسجيل)، وإذا ما فيه سجل فوزن الاستبيان */
export function currentWeight(logs: { logged_on: string; kg: number }[], intakeWeight: number | null): { kg: number; source: "logs" | "intake" } | null {
  if (logs.length) {
    const last = [...logs].sort((x, y) => x.logged_on.localeCompare(y.logged_on)).at(-1)!.logged_on;
    const from = new Date(Date.parse(`${last}T00:00:00Z`) - 6 * 86_400_000).toISOString().slice(0, 10);
    const recent = logs.filter((l) => l.logged_on >= from && l.logged_on <= last).map((l) => Number(l.kg));
    return { kg: Math.round((recent.reduce((s, v) => s + v, 0) / recent.length) * 10) / 10, source: "logs" };
  }
  return intakeWeight && intakeWeight > 0 ? { kg: intakeWeight, source: "intake" } : null;
}

/** ما الذي ينقص الحساب (حسب المعادلة) */
export function missingFor(p: CalorieProfile): string[] {
  if (p.method === "cunningham") return p.body_fat == null ? ["نسبة الدهون"] : [];
  if (p.method === "tenhaaf") return [p.height_cm == null && "الطول", p.age == null && "العمر", p.sex == null && "الجنس"].filter(Boolean) as string[];
  return [];
}

/** السعرات اليومية المستهدفة بحاسبة الموقع، مقرّبة لأقرب 5 */
export function targetKcal(p: CalorieProfile, weight: number): number | null {
  if (missingFor(p).length || !(weight > 0)) return null;
  const r = calculateIntake({
    method: p.method, weight, bodyFat: p.body_fat, heightCm: p.height_cm, age: p.age, sex: p.sex,
    paf: Number(p.paf), minutes: Number(p.minutes), trainingDays: Number(p.training_days), ebFactor: Number(p.eb_factor),
  });
  return Math.round(r.target / 5) * 5;
}

export const SUGGEST_THRESHOLD = 50;

/**
 * الاقتراح: فقط إذا اختلف عن الهدف الحالي بـ 50 سعرة أو أكثر ولم تتجاهله المدربة.
 * البروتين والدهون كما هي، والكارب يتعدّل ليطابق السعرات الجديدة.
 */
export function suggestTargets(p: CalorieProfile, w: { kg: number; source: "logs" | "intake" } | null, target: Target | null): Suggestion | null {
  if (!w) return null;
  const kcal = targetKcal(p, w.kg);
  if (kcal == null) return null;
  const cur = target?.kcal ?? null;
  if (cur != null && Math.abs(kcal - cur) < SUGGEST_THRESHOLD) return null;
  if (p.dismissed_kcal != null && p.dismissed_kcal === kcal) return null;
  const P = target?.protein ?? null, F = target?.fat ?? null;
  const rawCarbs = P != null && F != null ? (kcal - 4 * P - 9 * F) / 4 : null;
  const carbs = rawCarbs == null ? null : Math.max(0, Math.round(rawCarbs));
  return {
    kcal, protein: P, fat: F, carbs,
    diff: cur == null ? null : kcal - cur,
    lowCarb: rawCarbs != null && rawCarbs < 50,
    weight: w.kg, weightSource: w.source,
  };
}

const label = (list: readonly { v: string; l: string }[], v: number) => list.find((o) => Number(o.v) === Number(v))?.l ?? String(v);
/** سطر يشرح أساس الحساب للمدربة */
export function explain(p: CalorieProfile, s: Suggestion): string {
  return [
    `الوزن ${s.weight} كغ (${s.weightSource === "logs" ? "متوسط آخر 7 أيام" : "من الاستبيان"})`,
    `النشاط: ${label(PAF_LEVELS, p.paf)}`,
    `${p.training_days} أيام تمرين × ${p.minutes} دقيقة`,
    `الهدف: ${label(EB_GOALS, p.eb_factor)}`,
  ].join(" · ");
}
