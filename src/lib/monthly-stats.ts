import type { Tx } from "@/lib/db";

export type MonthRow = { ym: string; orders: number; members: number; revenue: number };
export type Goal = { members: number | null; revenue: number | null };
export type Goals = Record<string, Goal>;

const AR_MONTHS = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"];
export const monthName = (ym: string) => `${AR_MONTHS[Number(ym.slice(5, 7)) - 1]} ${ym.slice(0, 4)}`;

/** أرقام كل شهر (بتوقيت الرياض) من from إلى to (YYYY-MM): الطلبات بدون المجانية والتجريبية، الأعضاء الجدد،
 *  والمبالغ المدفوعة حسب شهر الدفع (بدون الملغاة والمجانية والتجريبية). الشهر الجديد يبدأ من صفر تلقائياً. */
export async function loadMonths(tx: Tx, from: string, to: string): Promise<MonthRow[]> {
  const { rows } = await tx.query(
    `SELECT to_char(m, 'YYYY-MM') AS ym,
            (SELECT count(*)::int FROM orders o WHERE NOT o.is_demo AND NOT o.is_free AND date_trunc('month', o.created_at AT TIME ZONE 'Asia/Riyadh') = m) AS orders,
            (SELECT count(*)::int FROM "user" u WHERE u.role = 'client' AND date_trunc('month', u."createdAt" AT TIME ZONE 'Asia/Riyadh') = m) AS members,
            (SELECT coalesce(sum(o.amount_due_halalas), 0)::bigint FROM orders o WHERE NOT o.is_demo AND NOT o.is_free AND o.paid_at IS NOT NULL AND o.status <> 'cancelled'
                AND date_trunc('month', o.paid_at AT TIME ZONE 'Asia/Riyadh') = m) AS revenue
       FROM generate_series(($1 || '-01')::timestamp, ($2 || '-01')::timestamp, interval '1 month') m ORDER BY m`, [from, to]);
  return rows.map((r) => ({ ym: r.ym, orders: r.orders, members: r.members, revenue: Number(r.revenue) / 100 }));
}

/** الأهداف تُحفظ بشهر بدايتها، وكل شهر يأخذ آخر هدف محفوظ قبله أو فيه (فتغيير الهدف ما يغيّر أهداف الأشهر السابقة). */
export async function loadGoals(tx: Tx): Promise<Goals> {
  const { rows } = await tx.query("SELECT value FROM site_settings WHERE key = 'monthly_goals'");
  return (rows[0]?.value ?? {}) as Goals;
}
export function goalFor(goals: Goals, ym: string): Goal {
  const key = Object.keys(goals).filter((k) => k <= ym).sort().pop();
  return key ? goals[key] : { members: null, revenue: null };
}
export const prevYm = (ym: string) => { const y = +ym.slice(0, 4), m = +ym.slice(5, 7); return m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, "0")}`; };
