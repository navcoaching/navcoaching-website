import "server-only";
import { withUser, type Tx } from "./db";
import { notifyTrainee, type ChannelResult } from "./notify";
import {
  DEFAULT_REMINDERS, type Reminders, daysBetween, fillTemplate, fmtYMD, reviewWeeks, riyadhDate, weekStatuses,
} from "./schedule";

export const SYSTEM_USER = "system-scheduler";

export async function loadReminders(tx: Tx): Promise<Reminders> {
  const { rows } = await tx.query("SELECT value FROM site_settings WHERE key = 'reminders'");
  return { ...DEFAULT_REMINDERS, ...(rows[0]?.value ?? {}) };
}

type ActiveOrder = {
  id: string; order_no: string; user_id: string; contact_name: string; product_name: string;
  sub_start_at: string; sub_end_at: string; review_weekday: number | null;
};

export async function loadWeekState(tx: Tx, o: ActiveOrder, r: Reminders, today = riyadhDate()) {
  if (o.review_weekday == null) return [];
  const weeks = reviewWeeks(o.sub_start_at, o.sub_end_at, o.review_weekday, r.review_window_days);
  const manual = new Set<number>((await tx.query("SELECT week_no FROM review_weeks WHERE order_id = $1", [o.id])).rows.map((x) => x.week_no));
  const checkins = (await tx.query("SELECT created_at FROM check_ins WHERE order_id = $1", [o.id])).rows.map((x) => x.created_at);
  return weekStatuses(weeks, manual, checkins, today);
}

/** نص تذكير المراجعة الذي يُعرض ويُرسل (نفسه في المعاينة والإرسال) */
export function reviewMessage(r: Reminders, name: string, w: { windowStart: string; windowEnd: string } | undefined) {
  if (!w) return fillTemplate("مرحباً {name}، تذكير بتحديث مراجعتك الأسبوعية من حسابك.", { name });
  return fillTemplate(r.review_text, { name, window_start: fmtYMD(w.windowStart), window_end: fmtYMD(w.windowEnd) });
}

const firstName = (n: string) => n.trim().split(/\s+/)[0] ?? n;

/**
 * يُشغَّل كل ساعة (Netlify Scheduled Function). لا يرسل خارج الساعة 9 صباحاً–9 مساءً بتوقيت الرياض.
 * كل تذكير يُرسل مرة واحدة لكل مناسبة وقناة (occasion_key فريد).
 */
export async function runReminders(now = new Date(), opts: { ignoreQuietHours?: boolean } = {}) {
  // انتهاء الاشتراكات يعمل في أي ساعة (لا يرسل شيئاً)
  const expired = await withUser(SYSTEM_USER, async (tx) => (await tx.query("SELECT app.expire_subscriptions() AS nos")).rows[0].nos as string[]);
  const hour = Number(new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Riyadh", hour: "numeric", hourCycle: "h23" }).format(now));
  if (!opts.ignoreQuietHours && (hour < 9 || hour >= 21)) return { skipped: "خارج ساعات الإرسال", expired, sent: [] };
  const today = riyadhDate(now);

  return withUser(SYSTEM_USER, async (tx) => {
    const r = await loadReminders(tx);
    const { rows: orders } = await tx.query<ActiveOrder>(
      `SELECT id, order_no, user_id, contact_name, product_name, sub_start_at, sub_end_at, review_weekday
         FROM orders WHERE status = 'active' AND category = 'follow' AND sub_start_at IS NOT NULL AND NOT is_demo`);
    const sent: { order: string; kind: string; results: ChannelResult[] }[] = [];

    for (const o of orders) {
      const target = { orderId: o.id, orderNo: o.order_no, userId: o.user_id };
      const name = firstName(o.contact_name);
      const end = riyadhDate(o.sub_end_at);
      const left = daysBetween(today, end);

      if (r.sub_expiry_days.includes(left)) {
        const text = fillTemplate(r.sub_expiry_text, { name, product: o.product_name, end_date: fmtYMD(end) });
        sent.push({ order: o.order_no, kind: "sub_expiry", results: await notifyTrainee(tx, target, {
          kind: "sub_expiry", subject: "تذكير: اشتراكك قرب ينتهي", text, occasion: `sub_expiry:${end}:${left}` }) });
      }

      const weeks = await loadWeekState(tx, o, r, today);
      const upcoming = weeks.find((w) => w.status !== "done" && w.windowEnd >= today);
      if (upcoming && daysBetween(today, upcoming.windowStart) <= r.review_lead_days && daysBetween(today, upcoming.windowStart) >= 0) {
        sent.push({ order: o.order_no, kind: "review_upcoming", results: await notifyTrainee(tx, target, {
          kind: "review_upcoming", subject: "تذكير بالمراجعة الأسبوعية", text: reviewMessage(r, name, upcoming),
          occasion: `review_upcoming:${upcoming.due}` }) });
      }
      // تذكير واحد لطيف بعد فوات موعد المراجعة (خلال 3 أيام من نهاية النافذة فقط)
      const missed = weeks.filter((w) => w.status === "missed").pop();
      if (missed && daysBetween(missed.windowEnd, today) >= 1 && daysBetween(missed.windowEnd, today) <= 3) {
        const text = fillTemplate(r.missed_review_text, { name, window_end: fmtYMD(missed.windowEnd) });
        sent.push({ order: o.order_no, kind: "review_missed", results: await notifyTrainee(tx, target, {
          kind: "review_missed", subject: "مراجعتك الأسبوعية", text, occasion: `review_missed:${missed.due}` }) });
      }
    }
    return { today, expired, checked: orders.length, sent };
  });
}
