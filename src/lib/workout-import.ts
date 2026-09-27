// تعبئة تسجيل التمرين من صورة تطبيق خارجي (مثل Strong): تطبيع الأسماء، مطابقة تمارين اليوم، وتحويل المجموعات.
// منطق خالص يُختبر مباشرة؛ قراءة الصورة نفسها في workout-vision.ts.

export type ExtractedSet = { weight: number | null; reps: number | null; rpe?: number | null; warmup?: boolean };
export type ExtractedExercise = { name: string; unit: "kg" | "lb" | null; sets: ExtractedSet[] };
export type DayItem = { id: string; exercise_id: string; name: string };
export type ImportLog = { weight: number; reps: number[]; rir: number | null };
export type ImportRow = { external: string; key: string; itemId: string | null; how: "alias" | "name" | "partial" | null; log: ImportLog | null };

const LB = 0.45359237;
// كلمات عامة لا تميّز التمرين (المعدات بين أقواس تُحذف أصلاً)
const NOISE = new Set(["the", "a", "exercise", "machine", "barbell", "dumbbell", "cable", "bb", "db", "smith"]);

/** اسم موحّد للمقارنة والحفظ: أحرف صغيرة، بدون ما بين الأقواس والرموز، والجمع البسيط مفرد */
export function normalizeName(s: string): string {
  return s.toLowerCase()
    .replace(/\([^)]*\)/g, " ")
    .replace(/[^a-z0-9؀-ۿ]+/g, " ")
    .split(" ").filter(Boolean)
    .map((w) => (w.length > 3 && w.endsWith("s") && !w.endsWith("ss") ? w.slice(0, -1) : w))
    .join(" ").trim();
}

const words = (s: string) => new Set(normalizeName(s).split(" ").filter((w) => w && !NOISE.has(w)));

/** تشابه الكلمات (Jaccard) بين اسمين بعد التطبيع */
function overlap(a: string, b: string): number {
  const A = words(a), B = words(b);
  if (!A.size || !B.size) return 0;
  let n = 0;
  for (const w of A) if (B.has(w)) n++;
  return n / (A.size + B.size - n);
}

/** مجموعات العمل (بدون إحماء) → وزن واحد (الأثقل) + تكرارات كل مجموعة، وRPE → RIR تقريبي */
export function toLog(ex: ExtractedExercise): ImportLog | null {
  const work = ex.sets.filter((s) => !s.warmup && s.reps != null && s.reps > 0);
  if (!work.length) return null;
  const factor = ex.unit === "lb" ? LB : 1;
  const kg = Math.max(0, ...work.map((s) => (s.weight ?? 0) * factor));
  const rpes = work.map((s) => s.rpe).filter((r): r is number => r != null && r >= 5 && r <= 10);
  const rir = rpes.length ? Math.max(0, Math.min(5, Math.round(10 - rpes[rpes.length - 1]))) : null;
  return { weight: Math.round(kg * 2) / 2, reps: work.map((s) => Math.round(s.reps!)).slice(0, 10), rir };
}

/**
 * مطابقة تمارين الصورة مع تمارين اليوم: الربط المحفوظ أولاً، ثم نفس الاسم، ثم تشابه الكلمات (≥ 0.5).
 * كل تمرين في اليوم يُستخدم مرة واحدة. غير المطابق يبقى itemId = null ليربطه المتدرب أو يتجاهله.
 */
export function matchExercises(extracted: ExtractedExercise[], day: DayItem[], aliases: Map<string, string>): ImportRow[] {
  const used = new Set<string>();
  const rows: ImportRow[] = extracted.map((ex) => ({ external: ex.name, key: normalizeName(ex.name), itemId: null, how: null, log: toLog(ex) }));
  const take = (r: ImportRow, it: DayItem | undefined, how: ImportRow["how"]) => {
    if (it && !used.has(it.id)) { r.itemId = it.id; r.how = how; used.add(it.id); }
  };
  for (const r of rows) {
    const exId = aliases.get(r.key);
    if (exId) take(r, day.find((d) => d.exercise_id === exId && !used.has(d.id)), "alias");
  }
  for (const r of rows) if (!r.itemId) take(r, day.find((d) => !used.has(d.id) && normalizeName(d.name) === r.key), "name");
  for (const r of rows) {
    if (r.itemId) continue;
    const best = day.filter((d) => !used.has(d.id)).map((d) => ({ d, s: overlap(r.external, d.name) })).sort((a, b) => b.s - a.s)[0];
    if (best && best.s >= 0.5) take(r, best.d, "partial");
  }
  return rows;
}
