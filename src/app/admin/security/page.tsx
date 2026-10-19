import type { Metadata } from "next";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";

export const metadata: Metadata = { title: "الأمان والمراقبة" };
export const dynamic = "force-dynamic";

const EVENT: Record<string, string> = {
  login_ok: "دخول ناجح", login_failed: "رمز خاطئ", login_locked: "محاولة أثناء القفل", otp_sent: "طلب رمز دخول", account_deleted: "حذف حساب",
};
const ISSUE: Record<string, string> = {
  server_error: "خطأ في الموقع", mail_failed: "فشل بريد", login_mail_failed: "فشل بريد رمز الدخول", push_failed: "فشل إشعار جوال", whatsapp_failed: "فشل واتساب",
};
const when = (d: Date) => new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { dateStyle: "short", timeStyle: "short", timeZone: "Asia/Riyadh" }).format(d);

export default async function AdminSecurity() {
  const coach = await requireCoach();
  const data = await withUser(coach.id, async (tx) => {
    // الصفحة لا تتعطل إذا نُشر الكود قبل ملف Neon
    if (!(await tx.query("SELECT to_regclass('public.security_log') AS t")).rows[0].t) return null;
    const [issues, logins, actions, day] = await Promise.all([
      tx.query("SELECT kind, detail, created_at FROM ops_events ORDER BY created_at DESC LIMIT 50"),
      tx.query("SELECT event, email, ip, detail, created_at FROM security_log ORDER BY created_at DESC LIMIT 100"),
      tx.query("SELECT l.action, l.target, l.created_at, u.email FROM admin_log l LEFT JOIN \"user\" u ON u.id = l.actor_id ORDER BY l.created_at DESC LIMIT 50"),
      tx.query(`SELECT count(*) FILTER (WHERE event = 'login_failed')::int AS failed, count(*) FILTER (WHERE event = 'login_locked')::int AS locked,
                       (SELECT count(*)::int FROM ops_events WHERE created_at > now() - interval '24 hours') AS issues
                  FROM security_log WHERE created_at > now() - interval '24 hours'`),
    ]);
    return { issues: issues.rows, logins: logins.rows, actions: actions.rows, day: day.rows[0] };
  });

  if (!data) return <div className="stack"><h1>الأمان والمراقبة</h1><p className="alert warn">شغّلي ملف <code>db/updates/2026-10-19-security-ops.sql</code> في Neon أولاً.</p></div>;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>الأمان والمراقبة</h1>
      <p className="muted small">آخر 24 ساعة: {data.day.issues} مشكلة تشغيل، {data.day.failed} رمز دخول خاطئ، {data.day.locked} محاولة أثناء القفل. يصلك تنبيه على الجوال (والبريد) عند أول مشكلة من كل نوع كل ساعة. السجل يُحذف تلقائياً بعد 180 يوماً، والتنبيهات بعد 90.</p>

      <section className="stack" style={{ ["--space" as string]: "8px" }}>
        <h2>مشاكل التشغيل</h2>
        {data.issues.length === 0 ? <p className="alert ok">لا توجد مشاكل مسجّلة.</p> : (
          <div className="table-wrap"><table className="t" data-testid="ops-events">
            <thead><tr><th>الوقت</th><th>النوع</th><th>التفاصيل</th></tr></thead>
            <tbody>{data.issues.map((r, i) => <tr key={i}><td>{when(r.created_at)}</td><td>{ISSUE[r.kind] ?? r.kind}</td><td dir="auto" className="small">{r.detail}</td></tr>)}</tbody>
          </table></div>
        )}
      </section>

      <section className="stack" style={{ ["--space" as string]: "8px" }}>
        <h2>محاولات الدخول</h2>
        <p className="muted small">بعد 5 رموز خاطئة لنفس البريد خلال 15 دقيقة يُقفل الدخول له 15 دقيقة.</p>
        <div className="table-wrap"><table className="t" data-testid="security-log">
          <thead><tr><th>الوقت</th><th>الحدث</th><th>البريد</th><th>IP</th></tr></thead>
          <tbody>{data.logins.map((r, i) => <tr key={i}><td>{when(r.created_at)}</td><td>{EVENT[r.event] ?? r.event}{r.detail ? <span className="muted small"> ({r.detail})</span> : null}</td><td dir="ltr">{r.email ?? "—"}</td><td dir="ltr" className="small">{r.ip ?? "—"}</td></tr>)}</tbody>
        </table></div>
      </section>

      <section className="stack" style={{ ["--space" as string]: "8px" }}>
        <h2>عمليات لوحة الإدارة</h2>
        <div className="table-wrap"><table className="t" data-testid="admin-actions">
          <thead><tr><th>الوقت</th><th>العملية</th><th>الهدف</th><th>بواسطة</th></tr></thead>
          <tbody>{data.actions.map((r, i) => <tr key={i}><td>{when(r.created_at)}</td><td dir="auto">{r.action}</td><td dir="auto" className="small">{r.target ?? "—"}</td><td dir="ltr" className="small">{r.email ?? "—"}</td></tr>)}</tbody>
        </table></div>
      </section>
    </div>
  );
}
