import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate, riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import ActionForm from "@/components/admin/ActionForm";
import { archiveOrderAction } from "@/app/actions/admin";

const STATUSES = ["", "awaiting_quote", "awaiting_payment", "payment_review", "preparing", "active", "delivered", "completed", "cancelled"];

export default async function AdminOrders({ searchParams }: { searchParams: Promise<{ status?: string; q?: string; view?: string; deleted?: string }> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const status = STATUSES.includes(sp.status ?? "") ? sp.status ?? "" : "";
  const q = (sp.q ?? "").trim().slice(0, 80);
  const archived = sp.view === "archived";
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT o.order_no, o.product_name, o.offer_label, o.status, o.category, o.amount_due_halalas, o.contact_name, o.contact_phone,
            o.created_at, o.student_discount_requested, o.is_demo, u.email, i.health_flag
       FROM orders o JOIN "user" u ON u.id = o.user_id LEFT JOIN intakes i ON i.order_id = o.id
      WHERE ($1 = '' OR o.status = $1)
        AND (o.archived_at IS NOT NULL) = $3
        AND ($2 = '' OR o.order_no ILIKE '%' || $2 || '%' OR o.contact_name ILIKE '%' || $2 || '%'
             OR o.contact_phone LIKE '%' || $2 || '%' OR u.email ILIKE '%' || $2 || '%')
      ORDER BY o.created_at DESC LIMIT 200`, [status, q, archived])).rows);

  return (
    <div>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>{archived ? "الطلبات المخفية" : "الطلبات"}</h1>
        <Link className="btn btn-ghost btn-sm" href={archived ? "/admin/orders" : "/admin/orders?view=archived"}>{archived ? "رجوع للطلبات" : "الطلبات المخفية"}</Link>
      </div>
      {sp.deleted && <p className="alert ok" style={{ marginBottom: 14 }}>تم حذف الطلب نهائياً.</p>}
      <nav className="pill-nav" aria-label="تصفية حسب الحالة">
        {STATUSES.map((st) => (
          <Link key={st || "all"} href={`/admin/orders?${new URLSearchParams({ ...(st ? { status: st } : {}), ...(q ? { q } : {}), ...(archived ? { view: "archived" } : {}) })}`} aria-current={st === status ? "true" : undefined}>
            {st ? statusLabel(st, "follow") : "الكل"}
          </Link>
        ))}
      </nav>
      <form className="filters" role="search">
        {status && <input type="hidden" name="status" value={status} />}
        {archived && <input type="hidden" name="view" value="archived" />}
        <div className="field"><label htmlFor="q">بحث برقم الطلب أو الاسم أو الجوال أو البريد</label><input id="q" name="q" type="search" defaultValue={q} /></div>
        <button className="btn btn-sm">بحث</button>
      </form>
      <div className="table-wrap">
        <table className="t">
          <thead><tr><th>رقم الطلب</th><th>العميل</th><th>البرنامج</th><th>المبلغ</th><th>الحالة</th><th>التاريخ</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={7} className="muted">لا توجد نتائج.</td></tr>}
            {rows.map((o) => (
              <tr key={o.order_no}>
                <td><Link href={`/admin/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link>{o.is_demo && <span className="tag demo" style={{ marginInlineStart: 6 }}>تجريبي</span>}</td>
                <td>{o.contact_name}<div className="small muted"><bdi dir="ltr">{o.contact_phone}</bdi></div></td>
                <td>{o.product_name}<div className="small muted">{o.offer_label}{o.student_discount_requested ? " · طالب" : ""}{o.health_flag ? " · ⚠︎ ملاحظة صحية" : ""}</div></td>
                <td className="num">{o.amount_due_halalas == null ? "—" : riyals(o.amount_due_halalas)}</td>
                <td><span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span></td>
                <td className="small">{fmtDate(o.created_at)}</td>
                <td>
                  <ActionForm action={archiveOrderAction} submit={archived ? "إظهار" : "إخفاء"} submitClass="btn btn-ghost btn-sm" className="row">
                    <input type="hidden" name="order_no" value={o.order_no} />
                    <input type="hidden" name="archive" value={archived ? "0" : "1"} />
                  </ActionForm>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
