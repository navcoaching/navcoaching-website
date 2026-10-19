import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDateTime } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import { moderateReviewAction } from "@/app/actions/admin";

const ST: Record<string, string> = { pending: "بانتظار المراجعة", published: "منشور", rejected: "مرفوض", hidden: "مخفي" };
const MODE: Record<string, string> = { full: "الاسم كامل", first: "الاسم الأول", anon: "بدون اسم" };

export default async function AdminReviews({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const status = Object.keys(ST).includes(sp.status ?? "") ? sp.status! : "pending";
  const { rows, log } = await withUser(coach.id, async (tx) => ({
    rows: (await tx.query(
      `SELECT r.*, o.order_no FROM reviews r LEFT JOIN orders o ON o.id = r.order_id WHERE r.status = $1 ORDER BY r.created_at DESC, r.sort`, [status])).rows,
    log: (await tx.query(
      `SELECT e.*, u.name FROM review_events e LEFT JOIN "user" u ON u.id = e.actor_id ORDER BY e.id DESC LIMIT 30`)).rows,
  }));

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>التقييمات</h1>
      <p className="small muted">لا يمكن تعديل نص أي تقييم. النشر يتطلب موافقة صاحبه. الرفض أو الإخفاء يتطلب سبباً وفق <Link href="/policies#reviews" target="_blank">سياسة التقييمات</Link>، ويُسجّل في السجل.</p>
      <nav className="pill-nav">{Object.entries(ST).map(([k, v]) => <Link key={k} href={`/admin/reviews?status=${k}`} aria-current={k === status ? "true" : undefined}>{v}</Link>)}</nav>
      {rows.length === 0 && <p className="muted">لا توجد تقييمات في هذه القائمة.</p>}
      {rows.map((r) => (
        <div key={r.id} className="card stack">
          <div className="row" style={{ justifyContent: "space-between" }}>
            <b>{r.display_name} <span className="small muted">({MODE[r.display_mode]})</span></b>
            <span className="small muted">
              {r.source === "legacy" ? `من الموقع السابق · ${r.period_label ?? ""}` : <>طلب <Link href={`/admin/orders/${r.order_no}`}><bdi>{r.order_no}</bdi></Link> · {fmtDateTime(r.created_at)}</>}
            </span>
          </div>
          {r.rating && <span className="stars">{"★".repeat(r.rating)}</span>}
          <blockquote style={{ margin: 0 }}>«{r.body}»</blockquote>
          <p className="small">{r.product_name} · موافقة على النشر: <b>{r.consent_publish ? "نعم" : "لا"}</b>{r.moderation_reason ? ` · السبب: ${r.moderation_reason}` : ""}</p>
          <div className="grid g2" style={{ alignItems: "start" }}>
            {r.status !== "published" && r.consent_publish && (
              <ActionForm action={moderateReviewAction} submit="اعتماد النشر" className="form card flat">
                <input type="hidden" name="id" value={r.id} /><input type="hidden" name="action" value="publish" />
                <label className="check"><input type="checkbox" name="checked" required /><span>راجعت النص: لا يحتوي أرقام هواتف أو بيانات صحية أو خاصة أو إساءة.</span></label>
              </ActionForm>
            )}
            {r.status !== "rejected" && r.status !== "hidden" && (
              <ActionForm action={moderateReviewAction} submit={r.status === "published" ? "إخفاء" : "رفض"} submitClass="btn btn-danger btn-sm" className="form card flat">
                <input type="hidden" name="id" value={r.id} /><input type="hidden" name="action" value={r.status === "published" ? "hide" : "reject"} />
                <div className="field"><label>السبب (وفق السياسة) *</label><input name="reason" type="text" required maxLength={300} /></div>
              </ActionForm>
            )}
            <ActionForm action={moderateReviewAction} submit="حفظ الرد" className="form card flat">
              <input type="hidden" name="id" value={r.id} /><input type="hidden" name="action" value="reply" />
              <div className="field"><label>ردك العلني (اختياري)</label><textarea name="reply" defaultValue={r.coach_reply ?? ""} maxLength={1000} /></div>
            </ActionForm>
          </div>
        </div>
      ))}
      <details className="card flat log">
        <summary style={{ cursor: "pointer" }}>سجل المراجعة (آخر 30)</summary>
        <ul>{log.map((e) => <li key={e.id}>{fmtDateTime(e.created_at)} — {e.name ?? "—"}: {e.action} {e.from_status ? `(${e.from_status} → ${e.to_status})` : ""} {e.reason ? `— ${e.reason}` : ""}</li>)}</ul>
      </details>
    </div>
  );
}
