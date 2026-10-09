// حسابات الاشتراك وجدول المراجعة الأسبوعية — كل التواريخ بتوقيت الرياض (بدون ساعات).
// منطق موثّق في docs/FOLLOWUP.md

const TZ = "Asia/Riyadh";
const DAY = 86_400_000;

/** تاريخ اليوم بصيغة YYYY-MM-DD بتوقيت الرياض */
export function riyadhDate(d: Date | string | number = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(d));
}
const toUTC = (ymd: string) => Date.UTC(+ymd.slice(0, 4), +ymd.slice(5, 7) - 1, +ymd.slice(8, 10));
export const addDays = (ymd: string, n: number) => new Date(toUTC(ymd) + n * DAY).toISOString().slice(0, 10);
export const daysBetween = (from: string, to: string) => Math.round((toUTC(to) - toUTC(from)) / DAY);
const weekday = (ymd: string) => new Date(toUTC(ymd)).getUTCDay();

export const WEEKDAYS = ["الأحد", "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];

export type SubState = "not_started" | "active" | "ending_soon" | "expired" | "cancelled";
export const SUB_LABEL: Record<SubState, string> = {
  not_started: "لم يبدأ", active: "فعّال", ending_soon: "قريب من الانتهاء", expired: "منتهٍ", cancelled: "ملغى",
};

/**
 * حالة الاشتراك:
 * - ملغى: حالة الطلب cancelled.
 * - لم يبدأ: لا يوجد تاريخ بدء (لم يُفعَّل بعد، أو منتج بدون مدة).
 * - منتهٍ: اليوم بعد تاريخ الانتهاء، أو الطلب مكتمل.
 * - قريب من الانتهاء: متبقٍ عدد أيام ≤ أكبر قيمة في إعداد «أيام التذكير قبل الانتهاء».
 * - فعّال: غير ذلك.
 */
export function subscriptionState(o: { status: string; sub_start_at: string | null; sub_end_at: string | null }, soonDays: number, today = riyadhDate()): SubState {
  if (o.status === "cancelled") return "cancelled";
  if (!o.sub_start_at || !o.sub_end_at) return "not_started";
  const end = riyadhDate(o.sub_end_at);
  if (o.status === "completed" || today > end) return "expired";
  return daysBetween(today, end) <= soonDays ? "ending_soon" : "active";
}

export type Week = { no: number; due: string; windowStart: string; windowEnd: string };

/**
 * مواعيد المراجعة كل everyWeeks أسبوع (1 = أسبوعية، 2 = كل أسبوعين للباقة الأساسية):
 * أول موعد = أول يوم مراجعة يقع بعد 7×everyWeeks يوماً على الأقل من تاريخ البدء، ثم كل 7×everyWeeks يوماً
 * حتى تاريخ الانتهاء. نافذة التسليم تبدأ يوم المراجعة وتستمر windowDays يوماً بعده.
 */
export function reviewWeeks(startISO: string, endISO: string, reviewWeekday: number, windowDays: number, everyWeeks = 1): Week[] {
  const start = riyadhDate(startISO), end = riyadhDate(endISO);
  const step = 7 * Math.min(4, Math.max(1, Math.round(everyWeeks) || 1));
  let due = addDays(start, step);
  while (weekday(due) !== reviewWeekday) due = addDays(due, 1);
  const out: Week[] = [];
  for (let no = 1; due <= end && no <= 200; no++, due = addDays(due, step)) {
    out.push({ no, due, windowStart: due, windowEnd: addDays(due, Math.max(0, windowDays)) });
  }
  return out;
}

/** «كل أسبوع» / «كل أسبوعين» / «كل 3 أسابيع» */
export const reviewEveryLabel = (n: number | null | undefined) =>
  !n || n <= 1 ? "كل أسبوع" : n === 2 ? "كل أسبوعين" : `كل ${n} أسابيع`;
/** عنوان المراجعة: «المراجعة الأسبوعية» أو «المراجعة (كل أسبوعين)» */
export const reviewTitle = (n: number | null | undefined) => (!n || n <= 1 ? "المراجعة الأسبوعية" : `المراجعة (${reviewEveryLabel(n)})`);

export type WeekStatus = "done" | "current" | "missed" | "upcoming";
export const WEEK_LABEL: Record<WeekStatus, string> = { done: "تمت المراجعة", current: "الأسبوع الحالي", missed: "لم تصل المراجعة", upcoming: "قادم" };

/**
 * تعتبر المراجعة منجزة إذا: علّمتها المدربة يدوياً، أو أرسل المتدرب مراجعة من الموقع
 * خلال الفترة من (موعد المراجعة − 3 أيام) إلى نهاية نافذة التسليم.
 */
export function weekStatuses(weeks: Week[], manualDone: Set<number>, checkinDates: string[], today = riyadhDate()) {
  const days = checkinDates.map((d) => riyadhDate(d));
  return weeks.map((w) => {
    const bySite = days.some((d) => d >= addDays(w.due, -3) && d <= w.windowEnd);
    const done = manualDone.has(w.no) || bySite;
    const status: WeekStatus = done ? "done" : today > w.windowEnd ? "missed" : today >= addDays(w.due, -6) ? "current" : "upcoming";
    return { ...w, status, source: manualDone.has(w.no) ? "manual" : bySite ? "site" : null };
  });
}

export function fillTemplate(t: string, vars: Record<string, string>) {
  return t.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? vars[k] : m));
}

export const fmtYMD = (ymd: string) =>
  new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(toUTC(ymd)));

/** موعد البداية الذي يختاره المتدرب: من بكرة إلى 31 يوماً (نفس الحد في app.set_my_start_pref) */
export const START_PREF_MAX_DAYS = 31;
export const startPrefRange = (today = riyadhDate()) => ({ min: addDays(today, 1), max: addDays(today, START_PREF_MAX_DAYS) });
export const validStartPref = (d: string, today = riyadhDate()) =>
  /^\d{4}-\d{2}-\d{2}$/.test(d) && d >= startPrefRange(today).min && d <= startPrefRange(today).max;

/** نص تاق موعد البداية للمدربة: «⚡ بأقرب وقت» أو «📅 يبدأ 12 أكتوبر · بعد 14 يوم» */
export function startPrefLabel(pref: string | null | undefined, today = riyadhDate()): { asap: boolean; text: string } {
  if (!pref) return { asap: true, text: "⚡ بأقرب وقت" };
  const n = daysBetween(today, pref);
  const when = n > 1 ? `بعد ${n} يوم` : n === 1 ? "بكرة" : n === 0 ? "اليوم" : "فات الموعد";
  return { asap: false, text: `📅 يبدأ ${fmtYMD(pref)} · ${when}` };
}

export type Reminders = {
  sub_expiry_days: number[]; sub_expiry_text: string; review_lead_days: number; review_window_days: number;
  review_text: string; missed_review_text: string; manual_cooldown_minutes: number;
  coach_digest: boolean; // إيميل يومي للمدربة بأسماء مراجعات اليوم
};
export const DEFAULT_REMINDERS: Reminders = {
  sub_expiry_days: [7, 3],
  sub_expiry_text: "مرحباً {name}، اشتراكك في {product} ينتهي بتاريخ {end_date}. للتجديد أو الاستفسار تواصل معنا.",
  review_lead_days: 1,
  review_window_days: 2,
  review_text: "مرحباً {name}، تذكير بموعد مراجعتك: المراجعة مفتوحة من {window_start} إلى {window_end}.",
  missed_review_text: "مرحباً {name}، ما وصلتنا مراجعتك اللي انتهى موعدها في {window_end}. متى ما تيسّر لك، حدّثها عشان نتابع تقدمك.",
  manual_cooldown_minutes: 10,
  coach_digest: true,
};
