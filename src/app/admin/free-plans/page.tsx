import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";

type Row = { id: string; slug: string; title: string; status: string; file_size: number | null; file_updated_at: string | null; requests: number; last_request: string | null };

export default async function AdminFreePlans() {
  const coach = await requireCoach();
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT p.id, p.slug, p.title, p.status, p.file_size, p.file_updated_at,
            count(r.id)::int AS requests, max(r.created_at) AS last_request
       FROM free_plans p LEFT JOIN free_plan_requests r ON r.plan_id = p.id
      GROUP BY p.id ORDER BY p.sort, p.created_at`)).rows as Row[]);
  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>الجداول المجانية</h1>
        <Link className="btn btn-sm" href="/admin/free-plans/new">+ جدول جديد</Link>
      </div>
      <p className="muted">الملفات تُحفظ في التخزين الخاص، ولا يحمّلها إلا من طلب الجدول وهو مسجّل الدخول. الجدول المخفي لا يظهر في الموقع ولا يمكن طلبه، ويبقى متاحاً لمن طلبه سابقاً.</p>
      <div className="table-wrap">
        <table className="t" data-testid="admin-free-plans">
          <thead><tr><th>الجدول</th><th>الحالة</th><th>الملف</th><th>الطلبات</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={5} className="muted">لا توجد جداول بعد. أضيفي أول جدول من «+ جدول جديد».</td></tr>}
            {rows.map((p) => (
              <tr key={p.id}>
                <td><b>{p.title}</b><div className="small muted"><bdi dir="ltr">/free-plans/{p.slug}</bdi></div></td>
                <td><span className={`status ${p.status === "published" ? "ok" : "muted"}`}>{p.status === "published" ? "منشور" : "مخفي"}</span></td>
                <td className="small">{p.file_size ? <>PDF · {(p.file_size / 1024 / 1024).toFixed(1)} م.ب{p.file_updated_at ? <div className="muted">{fmtDate(p.file_updated_at)}</div> : null}</> : <span className="muted">لا يوجد ملف</span>}</td>
                <td className="num">{p.requests}{p.last_request && <div className="small muted">آخر طلب {fmtDate(p.last_request)}</div>}</td>
                <td><Link className="btn btn-ghost btn-sm" href={`/admin/free-plans/${p.id}`}>تعديل</Link></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
