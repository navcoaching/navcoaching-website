import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";

type SP = { q?: string; view?: string };
type Row = { id: string; name: string; email: string; phone: string | null; created: string; last_seen: string | null; orders: number; active: number; verified: boolean; manual_only: boolean };

/** حسابات الأعضاء المسجلين (المتدربين) — للقراءة فقط، والتواصل والطلبات من الروابط */
export default async function Members({ searchParams }: { searchParams: Promise<SP> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const q = (sp.q ?? "").trim().slice(0, 80);
  const view = ["no_orders", "with_orders"].includes(sp.view ?? "") ? sp.view! : "";

  const { rows, stats } = await withUser(coach.id, async (tx) => {
    const base = `
      SELECT u.id, u.name, u.email, u.phone, u."createdAt" AS created, u."emailVerified" AS verified,
             (SELECT max(s."updatedAt") FROM "session" s WHERE s."userId" = u.id) AS last_seen,
             count(o.id) FILTER (WHERE NOT o.is_demo)::int AS orders,
             count(o.id) FILTER (WHERE NOT o.is_demo AND o.status IN ('active', 'delivered', 'preparing'))::int AS active,
             (count(o.id) > 0 AND bool_and(o.source = 'manual')) AS manual_only
        FROM "user" u LEFT JOIN orders o ON o.user_id = u.id
       WHERE u.role = 'client'
       GROUP BY u.id`;
    const rows = (await tx.query(
      `SELECT * FROM (${base}) m
        WHERE ($1 = '' OR m.name ILIKE '%' || $1 || '%' OR m.email ILIKE '%' || $1 || '%' OR coalesce(m.phone, '') LIKE '%' || $1 || '%')
          AND ($2 = '' OR ($2 = 'no_orders' AND m.orders = 0) OR ($2 = 'with_orders' AND m.orders > 0))
        ORDER BY m.created DESC LIMIT 300`, [q, view])).rows as Row[];
    const stats = (await tx.query(
      `SELECT count(*)::int AS total, count(*) FILTER (WHERE orders = 0)::int AS no_orders,
              count(*) FILTER (WHERE created > now() - interval '7 days')::int AS week
         FROM (${base}) m`)).rows[0] as { total: number; no_orders: number; week: number };
    return { rows, stats };
  });
  const link = (over: Partial<SP>) => `/admin/members?${new URLSearchParams(Object.entries({ q, view, ...over }).filter(([, v]) => v) as [string, string][])}`;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>الأعضاء المسجلون</h1>
        <Link className="btn btn-sm" href="/admin/orders/new">+ إضافة برنامج لمتدرب يدوياً</Link>
      </div>
      <div className="grid g4">
        <div className="card stat"><span className="muted">كل الأعضاء</span><b>{stats.total}</b></div>
        <div className="card stat"><span className="muted">سجّلوا بدون طلب</span><b>{stats.no_orders}</b></div>
        <div className="card stat"><span className="muted">جدد آخر 7 أيام</span><b>{stats.week}</b></div>
      </div>
      <nav className="pill-nav" aria-label="تصفية الأعضاء">
        {[["", "الكل"], ["with_orders", "عندهم طلبات"], ["no_orders", "بدون طلبات"]].map(([v, l]) => (
          <Link key={v || "all"} href={link({ view: v })} aria-current={v === view ? "true" : undefined}>{l}</Link>
        ))}
      </nav>
      <form className="filters" role="search">
        {view && <input type="hidden" name="view" value={view} />}
        <div className="field"><label htmlFor="mq">بحث بالاسم أو البريد أو الجوال</label><input id="mq" name="q" type="search" defaultValue={q} /></div>
        <button className="btn btn-sm">عرض</button>
      </form>
      <div className="table-wrap">
        <table className="t" data-testid="members">
          <thead><tr><th>العضو</th><th>التسجيل</th><th>آخر دخول</th><th>الطلبات</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={5} className="muted">لا توجد نتائج.</td></tr>}
            {rows.map((m) => (
              <tr key={m.id}>
                <td>
                  <b>{m.name && !m.name.includes("@") ? m.name : "—"}</b>
                  <div className="small"><bdi dir="ltr">{m.email}</bdi></div>
                  {m.phone && <div className="small muted"><bdi dir="ltr">{m.phone}</bdi></div>}
                </td>
                <td className="small">{fmtDate(m.created)}</td>
                <td className="small">{m.last_seen ? fmtDate(m.last_seen) : <span className="muted">{m.verified ? "—" : "لم يدخل بعد"}</span>}</td>
                <td>
                  {m.orders > 0
                    ? <Link href={`/admin/orders?q=${encodeURIComponent(m.email)}`}>{m.orders} {m.orders === 1 ? "طلب" : "طلبات"}{m.active ? ` · ${m.active} فعّال` : ""}</Link>
                    : <span className="muted">لا يوجد</span>}
                  {m.manual_only && <div className="small muted">يدوي</div>}
                </td>
                <td><Link className="btn btn-ghost btn-sm" href={`/admin/orders/new?email=${encodeURIComponent(m.email)}`}>إضافة برنامج</Link></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
