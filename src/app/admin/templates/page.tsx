import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";

type Row = { id: string; name: string; weeks: number; archived: boolean; days: number; items: number; blocks: number; updated_at: string };

/** قوالب البرامج: تُبنى مرة وتُسند للمتدربين ثم تُعدّل لكل متدرب */
export default async function Templates() {
  const coach = await requireCoach();
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT t.id, t.name, t.weeks, t.archived, t.updated_at,
            (SELECT count(*)::int FROM template_days d WHERE d.template_id = t.id) AS days,
            (SELECT count(*)::int FROM template_items i JOIN template_days d ON d.id = i.day_id WHERE d.template_id = t.id) AS items,
            (SELECT count(*)::int FROM blocks b WHERE b.template_id = t.id) AS blocks
       FROM program_templates t ORDER BY t.archived, t.updated_at DESC`)).rows as Row[]);
  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>قوالب البرامج</h1>
        <div className="row" style={{ gap: 8 }}>
          <Link className="btn btn-ghost btn-sm" href="/admin/templates/import" data-testid="import-template">استيراد من ملف</Link>
          <Link className="btn btn-sm" href="/admin/templates/new">+ قالب جديد</Link>
        </div>
      </div>
      <p className="muted">ابني القالب (الأيام والتمارين وخطة كل أسبوع) مرة واحدة، ثم أسنديه لأي متدرب من صفحة طلبه ← «برنامج التمرين». الإسناد ينسخ القالب، فتعديل القالب لاحقاً لا يغيّر برامج المتدربين الحالية.</p>
      <div className="table-wrap">
        <table className="t cards" data-testid="admin-templates">
          <thead><tr><th>القالب</th><th>الأسابيع</th><th>الأيام</th><th>التمارين</th><th>أُسند</th><th>آخر تعديل</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={7} className="muted empty-cta">لا توجد قوالب بعد. <Link className="btn btn-sm" href="/admin/templates/new">+ قالب جديد</Link></td></tr>}
            {rows.map((t) => (
              <tr key={t.id}>
                <td data-label="القالب"><b>{t.name}</b>{t.archived && <> <span className="status muted">مؤرشف</span></>}</td>
                <td data-label="الأسابيع" className="num">{t.weeks}</td><td data-label="الأيام" className="num">{t.days}</td><td data-label="التمارين" className="num">{t.items}</td><td data-label="أُسند" className="num">{t.blocks}</td>
                <td data-label="آخر تعديل" className="small">{fmtDate(t.updated_at)}</td>
                <td data-label=""><Link className="btn btn-ghost btn-sm" href={`/admin/templates/${t.id}`}>فتح</Link></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
