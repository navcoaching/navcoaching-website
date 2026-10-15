// الالتزام = تسجيل التمرين + المراجعة الأسبوعية، لكل أسبوع من أسابيع الاشتراك (بتوقيت الرياض).
// منطق خالص بدون قاعدة بيانات حتى يُختبر مباشرة؛ التحميل في loadAdherence (program-data.ts).
import type { WeekStatus } from "./schedule";

// التواريخ هنا YYYY-MM-DD بتوقيت الرياض (يحوّلها المستدعي عبر riyadhDate)
const addDays = (ymd: string, n: number) =>
  new Date(Date.UTC(+ymd.slice(0, 4), +ymd.slice(5, 7) - 1, +ymd.slice(8, 10)) + n * 86_400_000).toISOString().slice(0, 10);

export const REWARD_MIN = 0.9;      // 90% فأكثر
export const REWARD_WEEKS = 12;     // ≈ 3 أشهر من الأسابيع المكتملة
export const REWARD_MIN_MONTHS = 3; // لباقات 3 أشهر فأكثر

/** أسبوع من برنامج التمرين: تاريخ بدايته، وعدد التمارين المسجّلة من المطلوبة */
export type TrainingWeek = { start: string; logged: number; total: number };
/** مراجعة الأسبوع رقم no وحالتها (من weekStatuses): المراجعة رقم n تخص أسبوع الاشتراك n */
export type ReviewWeek = { no: number; status: WeekStatus };

export type AdherenceWeek = { no: number; start: string; end: string; training: number | null; review: number | null; score: number | null };
export type Adherence = {
  weeks: AdherenceWeek[];   // الأسابيع المكتملة فقط
  scored: number;           // عدد الأسابيع المكتملة التي لها درجة
  avg: number | null;       // متوسط الالتزام 0..1
  streak: number;           // أسابيع متتالية أخيرة بالتزام ≥ 90%
  rewardable: boolean;      // الباقة تؤهل للمكافأة
  weeksLeft: number;        // أسابيع باقية للوصول لـ 12 أسبوعاً
  eligible: boolean;        // مستحق للمكافأة الآن
};

const EPS = 1e-9;
const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

export function computeAdherence(input: {
  subStart: string; subEnd: string; months: number; today: string;
  training: TrainingWeek[]; reviews: ReviewWeek[]; isReward?: boolean;
}): Adherence {
  const { today, subStart: start, subEnd: end } = input;
  const weeks: AdherenceWeek[] = [];
  // الأسبوع k = [start + 7(k−1), start + 7k)، ويُحسب فقط إذا انتهى (نهايته ≤ اليوم) وضمن الاشتراك
  for (let k = 1; k <= 200; k++) {
    const ws = addDays(start, 7 * (k - 1)), we = addDays(start, 7 * k);
    if (ws >= end || we > today) break;
    const inWeek = (d: string) => d >= ws && d < we;
    const tr = input.training.filter((t) => t.total > 0 && inWeek(t.start));
    const training = tr.length ? Math.min(1, tr.reduce((a, t) => a + t.logged, 0) / tr.reduce((a, t) => a + t.total, 0)) : null;
    const rv = input.reviews.filter((r) => r.no === k && (r.status === "done" || r.status === "missed"));
    const review = rv.length ? rv.filter((r) => r.status === "done").length / rv.length : null;
    const score = mean([training, review].filter((x): x is number => x != null));
    weeks.push({ no: k, start: ws, end: addDays(we, -1), training, review, score });
  }
  const scoredWeeks = weeks.filter((w) => w.score != null);
  const avg = mean(scoredWeeks.map((w) => w.score!));
  let streak = 0;
  for (let i = scoredWeeks.length - 1; i >= 0 && scoredWeeks[i].score! >= REWARD_MIN - EPS; i--) streak++;
  const rewardable = input.months >= REWARD_MIN_MONTHS && !input.isReward;
  const eligible = rewardable && scoredWeeks.length >= REWARD_WEEKS && avg != null && avg >= REWARD_MIN - EPS;
  return { weeks, scored: scoredWeeks.length, avg, streak, rewardable, weeksLeft: Math.max(0, REWARD_WEEKS - scoredWeeks.length), eligible };
}

export const pct = (x: number | null) => (x == null ? "—" : `${Math.round(x * 100)}%`);
