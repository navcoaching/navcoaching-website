// عدد الجولات الأسبوعية لكل عضلة (للمدربة): العضلة الأساسية = جولة كاملة، والثانوية = نصف جولة.
// الحدود (أدنى/أعلى) تضعها المدربة لكل عضلة، ولا أرقام افتراضية من الموقع.
import type { PlanWeek } from "./training.ts";

export type VolumeItem = { name?: string | null; pattern?: string | null; sub_pattern?: string | null; primary_muscle?: string | null; secondary_muscles?: string[] | null; plan: PlanWeek[] };
export type Limits = Record<string, { min?: number | null; max?: number | null }>;

/** الحد الافتراضي لكل عضلة (من المدربة): 6 إلى 20 جولة أسبوعياً، ويتعدّل لكل عضلة من «تعديل الحدود» */
export const DEFAULT_VOLUME_LIMIT = { min: 6, max: 20 };

/** تصنيفات في المكتبة ليست عضلات، فلا تُحسب في الحجم */
export const NOT_MUSCLES = ["Functional", "Stretching", "Plyometrics", "CrossFit"];
const isMuscle = (m: string | null | undefined): m is string => Boolean(m) && !NOT_MUSCLES.some((x) => m!.startsWith(x));

/** الأكتاف تُحسب بثلاثة رؤوس (أمامي/جانبي/خلفي)، ومن تمارين الأكتاف الأساسية فقط (الثانوية من الصدر والظهر لا تدخل) */
export const SHOULDER_HEADS = { front: "Front Delts / الكتف الأمامي", side: "Side Delts / الكتف الجانبي", rear: "Rear Delts / الكتف الخلفي" } as const;
export const SHOULDER_HEAD_LIST: string[] = Object.values(SHOULDER_HEADS);
export const isShoulders = (m: string | null | undefined) => Boolean(m) && m!.startsWith("Shoulders");

/** رأس الكتف المستهدف: من نمط الحركة أولاً، ثم من اسم التمرين */
export function shoulderHead(it: Pick<VolumeItem, "name" | "pattern" | "sub_pattern">): string {
  const p = `${it.pattern ?? ""} ${it.sub_pattern ?? ""}`;
  if (/Rear|High Row|Face Pull/i.test(p)) return SHOULDER_HEADS.rear;
  if (/Front Raise/i.test(p)) return SHOULDER_HEADS.front;
  if (/Lateral Raise|Y Raise|Diagonal/i.test(p)) return SHOULDER_HEADS.side;
  if (/Vertical Push|Shoulder Press/i.test(p)) return SHOULDER_HEADS.front;
  const n = it.name ?? "";
  if (/rear|reverse|face\s*pull|high row|bent/i.test(n)) return SHOULDER_HEADS.rear;
  if (/front|press|push/i.test(n)) return SHOULDER_HEADS.front;
  return SHOULDER_HEADS.side;
}

/** لكل أسبوع: خريطة العضلة ← عدد الجولات (مقرّب لنصف) */
export function weeklyVolume(items: VolumeItem[], weeks: number): Map<string, number>[] {
  const out = Array.from({ length: weeks }, () => new Map<string, number>());
  const add = (m: Map<string, number>, k: string, v: number) => m.set(k, (m.get(k) ?? 0) + v);
  for (const it of items) {
    if (!isMuscle(it.primary_muscle)) continue; // إطالات/وظيفية… لا تُحسب ولا عضلاتها الثانوية
    for (let w = 0; w < weeks; w++) {
      const sets = it.plan[w]?.sets ?? 0;
      if (!sets) continue;
      add(out[w], isShoulders(it.primary_muscle) ? shoulderHead(it) : it.primary_muscle, sets);
      for (const s of new Set(it.secondary_muscles ?? [])) if (isMuscle(s) && s !== it.primary_muscle && !isShoulders(s)) add(out[w], s, sets / 2);
    }
  }
  return out;
}

/** العضلات المرتبة: الأكثر جولات أولاً (حسب مجموع كل الأسابيع)، ثم العضلات اللي لها حدود ولم تُستهدف */
export function muscleOrder(vol: Map<string, number>[], limits: Limits = {}): string[] {
  const total = new Map<string, number>();
  for (const m of vol) for (const [k, v] of m) total.set(k, (total.get(k) ?? 0) + v);
  for (const k of Object.keys(limits)) if (limits[k]?.min && !total.has(k)) total.set(k, 0);
  return [...total.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([k]) => k);
}

export type Status = "low" | "high" | "ok" | "none";
export function volumeStatus(sets: number, l?: { min?: number | null; max?: number | null }): Status {
  if (!l || (l.min == null && l.max == null)) return "none";
  if (l.min != null && sets < l.min) return "low";
  if (l.max != null && sets > l.max) return "high";
  return "ok";
}

/** «Chest / الصدر» ← «Chest» (أسماء العضلات بالإنجليزي في جدول المدربة) */
export const muscleLabel = (m: string) => m.split("/")[0].trim() || m;
