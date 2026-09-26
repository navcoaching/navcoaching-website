import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate, riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import ActionForm from "@/components/admin/ActionForm";
import PackageTag from "@/components/admin/PackageTag";
import { archiveOrderAction } from "@/app/actions/admin";

const STATUSES = ["", "awaiting_quote", "awaiting_payment", "payment_review", "preparing", "active", "delivered", "completed", "cancelled"];
const UUID = /^[0-9a-f-]{36}$/;

type SP = { status?: string; q?: string; view?: string; deleted?: string; pkg?: string };

export default async function AdminOrders({ searchParams }: { searchParams: Promise<SP> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const status = STATUSES.includes(sp.status ?? "") ? sp.status ?? "" : "";
  const q = (sp.q ?? "").trim().slice(0, 80);
  const archived = sp.view === "archived";
  const pkg = sp.pkg && UUID.test(sp.pkg) ? sp.pkg : "";

  const { rows, packages } = await withUser(coach.id, async (tx) => ({
    // البحث يشمل رقم الطلب والاسم والجوال والبريد، وملاحظات المدربة الخاصة
    rows: (await tx.query(
      `SELECT o.order_no, o.product_id, o.product_name, p.name AS current_name, o.offer_label, o.status, o.category,
              o.amount_due_halalas, o.contact_name, o.contact_phone, o.created_at, o.student_discount_requested, o.is_demo, o.source,
              u.email, i.health_flag, EXISTS (SELECT 1 FROM order_note_entries n WHERE n.order_id = o.id) AS has_note
         FROM orders o JOIN "user" u ON u.id = o.user_id
         LEFT JOIN intakes i ON i.order_id = o.id
         LEFT JOIN products p ON p.id = o.product_id
        WHERE ($1 = '' OR o.status = $1)
          AND (o.archived_at IS NOT NULL) = $3
          AND ($4 = '' OR o.product_id::text = $4)
          AND ($2 = '' OR o.order_no ILIKE '%' || $2 || '%' OR o.contact_name ILIKE '%' || $2 || '%'
               OR o.contact_phone LIKE '%' || $2 || '%' OR u.email ILIKE '%' || $2 || '%' OR EXISTS (SELECT 1 FROM order_note_entries n WHERE n.order_id = o.id AND n.body ILIKE '%' || $2 || '%'))
        ORDER BY o.created_at DESC LIMIT 200`, [status, q, archived, pkg])).rows,
    packages: (await tx.query(
      `SELECT o.product_id, coalesce(p.name, max(o.product_name)) AS name, count(*)::int AS n
         FROM orders o LEFT JOIN products p ON p.id = o.product_id
        WHERE o.product_id IS NOT NULL GROUP BY o.product_id, p.name ORDER BY name`)).rows as { product_id: string; name: string; n: number }[],
  }));

  const link = (over: Partial<SP>) => {
    const params = { status, q, pkg, ...(archived ? { view: "archived" } : {}), ...over };
    return `/admin/orders?${new URLSearchParams(Object.entries(params).filter(([, v]) => v) as [string, string][])}`;
  };

  return (
    <div>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>{archived ? "الطلبات المخفية" : "الطلبات"}</h1>
        <div className="row">
          <Link className="btn btn-sm" href="/admin/orders/new">+ طلب يدوي</Link>
          <Link className="btn btn-ghost btn-sm" href={archived ? "/admin/orders" : "/admin/orders?view=archived"}>{archived ? "رجوع للطلبات" : "الطلبات المخفية"}</Link>
        </div>
      </div>
      {sp.deleted && <p className="alert ok" style={{ marginBottom: 14 }}>تم حذف الطلب نهائياً.</p>}
      <nav className="pill-nav" aria-label="تصفية حسب الحالة">
        {STATUSES.map((st) => (
          <Link key={st || "all"} href={link({ status: st })} aria-current={st === status ? "true" : undefined}>
            {st ? statusLabel(st, "follow") : "الكل"}
          </Link>
        ))}
      </nav>
      <form className="filters" role="search">
        {status && <input type="hidden" name="status" value={status} />}
        {archived && <input type="hidden" name="view" value="archived" />}
        <div className="field"><label htmlFor="q">بحث برقم الطلب أو الاسم أو الجوال أو البريد أو الملاحظات</label><input id="q" name="q" type="search" defaultValue={q} /></div>
        <div className="field">
          <label htmlFor="pkg">الباقة</label>
          <select id="pkg" name="pkg" defaultValue={pkg}>
            <option value="">كل الباقات</option>
            {packages.map((p) => <option key={p.product_id} value={p.product_id}>{p.name} ({p.n})</option>)}
          </select>
        </div>
        <button className="btn btn-sm">عرض</button>
      </form>
      <div className="table-wrap">
        <table className="t">
          <thead><tr><th>رقم الطلب</th><th>العميل</th><th>الباقة</th><th>المبلغ</th><th>الحالة</th><th>التاريخ</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={7} className="muted">لا توجد نتائج.</td></tr>}
            {rows.map((o) => (
              <tr key={o.order_no}>
                <td>
                  <Link href={`/admin/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link>
                  {o.has_note && <span className="note-dot" role="img" aria-label="توجد ملاحظة خاصة" title="توجد ملاحظة خاصة">✎</span>}
                  {o.is_demo && <span className="tag demo" style={{ marginInlineStart: 6 }}>تجريبي</span>}
                  {o.source === "manual" && <span className="tag soft" style={{ marginInlineStart: 6 }}>يدوي</span>}
                </td>
                <td>{o.contact_name}<div className="small muted"><bdi dir="ltr">{o.contact_phone}</bdi></div></td>
                <td>
                  <Link href={link({ pkg: o.product_id ?? "" })} style={{ textDecoration: "none" }} aria-label={`تصفية حسب ${o.product_name}`}>
                    <PackageTag name={o.product_name} productId={o.product_id} currentName={o.current_name} />
                  </Link>
                  <div className="small muted">{o.offer_label}{o.student_discount_requested ? " · طالب" : ""}{o.health_flag ? " · ⚠︎ ملاحظة صحية" : ""}</div>
                </td>
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
