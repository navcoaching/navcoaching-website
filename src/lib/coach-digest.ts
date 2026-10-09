import "server-only";
import type { Tx } from "./db";
import { fmtYMD, type Reminders } from "./schedule";
import { prefetchOrders } from "./order-prefetch";
import { loadWeekState } from "./reminders";
import { loadPendingSuggestions } from "./calorie-data";
import { notifySafe } from "./mail";

export type DigestLine = { name: string; order_no: string; note: string };
export type Digest = { startsToday: DigestLine[]; open: DigestLine[]; awaitingReply: DigestLine[]; calories: DigestLine[] };

/** محتوى الإيميل اليومي للمدربة: أسماء وروابط فقط، بدون أي بيانات صحية */
export async function buildDigest(tx: Tx, r: Reminders, today: string): Promise<Digest> {
  const d: Digest = { startsToday: [], open: [], awaitingReply: [], calories: [] };
  const { rows: orders } = await tx.query(
    `SELECT id, order_no, user_id, contact_name, product_name, sub_start_at, sub_end_at, review_weekday
       FROM orders WHERE status = 'active' AND category = 'follow' AND sub_start_at IS NOT NULL AND NOT is_demo AND archived_at IS NULL
      ORDER BY contact_name`);
  await prefetchOrders(tx, orders.map((o) => o.id as string));
  for (const o of orders) {
    const weeks = await loadWeekState(tx, o, r, today);
    const w = weeks.find((x) => x.status !== "done" && x.windowStart <= today && x.windowEnd >= today);
    if (!w) continue;
    const line = { name: o.contact_name, order_no: o.order_no, note: `${o.product_name} · الأسبوع ${w.no}` };
    if (w.windowStart === today) d.startsToday.push(line);
    else d.open.push({ ...line, note: `${line.note} · آخر موعد ${fmtYMD(w.windowEnd)}` });
  }
  const { rows: waiting } = await tx.query(
    `SELECT o.order_no, o.contact_name, count(*)::int n FROM check_ins c JOIN orders o ON o.id = c.order_id
      WHERE c.replied_at IS NULL AND NOT o.is_demo AND o.status IN ('active', 'delivered')
      GROUP BY o.order_no, o.contact_name ORDER BY min(c.created_at)`);
  for (const x of waiting) d.awaitingReply.push({ name: x.contact_name, order_no: x.order_no, note: x.n > 1 ? `${x.n} مراجعات` : "مراجعة واحدة" });
  for (const s of await loadPendingSuggestions(tx)) {
    d.calories.push({ name: s.name, order_no: s.order_no, note: `${s.kcal.toLocaleString("en-US")} سعرة (${s.diff > 0 ? "+" : ""}${s.diff})` });
  }
  return d;
}

export const digestCount = (d: Digest) => d.startsToday.length + d.open.length + d.awaitingReply.length + d.calories.length;

export function digestText(d: Digest, today: string, site: string): string {
  const sec = (title: string, list: DigestLine[], path = "") =>
    list.length ? [`${title} (${list.length}):`, ...list.map((l) => `• ${l.name} — ${l.note}\n  ${site}/admin/orders/${l.order_no}${path}`), ""] : [];
  return [
    `مراجعات اليوم — ${fmtYMD(today)}`, "",
    ...sec("📅 مراجعات تبدأ اليوم", d.startsToday),
    ...sec("⏳ مراجعات مفتوحة ولم تصل بعد", d.open),
    ...sec("💬 مراجعات وصلت وتنتظر ردك", d.awaitingReply),
    ...sec("🔥 سعرات مقترحة جديدة", d.calories, "/nutrition"),
    "تقدرين توقفين هذا الإيميل من لوحة الإدارة ← المحتوى والإعدادات ← التنبيهات.",
  ].join("\n");
}

/** نسخة HTML منظّمة: قسم لكل نوع، وصف لكل متدرب بزر يفتح صفحته في لوحة الإدارة */
export function digestEmail(d: Digest, today: string, site: string) {
  const items = (list: DigestLine[], path = "") => list.map((l) => ({ name: l.name, note: l.note, url: `${site}/admin/orders/${l.order_no}${path}` }));
  const n = digestCount(d);
  return {
    headline: "مراجعات اليوم",
    message: `${fmtYMD(today)}\nعندك ${n} ${n === 1 ? "بند" : n === 2 ? "بندان" : n <= 10 ? "بنود" : "بنداً"} اليوم.`,
    sections: [
      { title: "📅 مراجعات تبدأ اليوم", items: items(d.startsToday) },
      { title: "⏳ مراجعات مفتوحة ولم تصل بعد", items: items(d.open) },
      { title: "💬 مراجعات وصلت وتنتظر ردك", items: items(d.awaitingReply, "#checkins") },
      { title: "🔥 سعرات مقترحة جديدة", items: items(d.calories, "/nutrition") },
    ],
    cta: { label: "فتح لوحة الإدارة", url: `${site}/admin` },
    footnote: "تقدرين توقفين هذا الإيميل من لوحة الإدارة ← المحتوى والإعدادات ← التنبيهات.",
  };
}

/**
 * يرسل الإيميل اليومي مرة واحدة فقط في اليوم (أول تشغيل للتذكيرات بعد 9 صباحاً)، وفقط إذا فيه أسماء.
 * يرجع عدد البنود المرسلة، أو null إذا لم يُرسل.
 */
export async function sendCoachDigest(tx: Tx, r: Reminders, today: string): Promise<number | null> {
  const to = process.env.COACH_NOTIFY_EMAIL;
  if (!r.coach_digest || !to) return null;
  if ((await tx.query(`SELECT 1 FROM coach_digests WHERE day = $1`, [today])).rowCount) return null;
  const d = await buildDigest(tx, r, today);
  const n = digestCount(d);
  if (!n) return null;
  const { rowCount } = await tx.query(`INSERT INTO coach_digests (day, items) VALUES ($1, $2) ON CONFLICT (day) DO NOTHING`, [today, n]);
  if (!rowCount) return null; // تشغيل آخر أرسله في نفس اللحظة
  const site = (process.env.NEXT_PUBLIC_SITE_URL || "https://navcoaching.com").replace(/\/$/, "");
  await notifySafe(to, `مراجعات اليوم (${n}) — ${fmtYMD(today)}`, digestText(d, today, site), digestEmail(d, today, site));
  return n;
}
