import { withUser } from "@/lib/db";
import SizedFileInput from "@/components/admin/SizedFileInput";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import { deleteBookletAction, saveBookletAction, uploadBookletAction } from "@/app/actions/booklets";

export const metadata = { title: "الكتيبات" };

type Row = { id: string; title: string; description: string | null; file_size: number; published: boolean; created_at: string };

/** الكتيبات: ملفات PDF تظهر للمتدربين في «حسابي ← تحميل الكتيبات» */
export default async function AdminBooklets() {
  const coach = await requireCoach();
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT id, title, description, file_size, published, created_at FROM booklets ORDER BY sort, created_at`)).rows as Row[]);
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 900 }}>
      <h1>الكتيبات</h1>
      <p className="muted">تظهر في صفحة المتدرب تحت «تحميل الكتيبات» لكل من عنده اشتراك (نشط أو تم التسليم أو مكتمل). الملفات في التخزين الخاص، وما يحمّلها إلا المتدرب وهو مسجّل الدخول.</p>

      <section className="card stack" data-testid="booklet-upload">
        <h2 style={{ fontSize: 19 }}>رفع كتيب</h2>
        <ActionForm action={uploadBookletAction} submit="رفع الكتيب" resetOnSuccess>
          <div className="field"><label htmlFor="bk-title">اسم الكتيب</label><input id="bk-title" name="title" required maxLength={120} /></div>
          <div className="field"><label htmlFor="bk-desc">وصف قصير (اختياري)</label><input id="bk-desc" name="description" maxLength={300} /></div>
          <div className="field"><label htmlFor="bk-file">ملف PDF</label><SizedFileInput id="bk-file" name="file" accept="application/pdf,.pdf" required /></div>
          <label className="row" style={{ gap: 8 }}><input type="checkbox" name="published" defaultChecked /> يظهر للمتدربين</label>
          <span className="hint">PDF فقط، وحجمه 5 ميجابايت أو أقل. لو أكبر: من كانفا اختاري «PDF Standard» بدل «PDF Print»، أو اضغطيه قبل الرفع.</span>
        </ActionForm>
      </section>

      <section className="stack" style={{ ["--space" as string]: "12px" }} data-testid="booklet-list">
        <h2 style={{ fontSize: 19 }}>الكتيبات المرفوعة ({rows.length})</h2>
        {rows.length === 0 && <p className="small muted">ما فيه كتيبات بعد.</p>}
        {rows.map((b) => (
          <div key={b.id} className="card stack" style={{ ["--space" as string]: "10px" }} data-testid="booklet-row">
            <div className="row" style={{ justifyContent: "space-between", flexWrap: "wrap", gap: 8 }}>
              <span><b>{b.title}</b> <span className={`status ${b.published ? "ok" : "muted"}`}>{b.published ? "ظاهر" : "مخفي"}</span></span>
              <span className="small muted">PDF · <span className="num">{(b.file_size / 1024 / 1024).toFixed(1)}</span> م.ب · {fmtDate(b.created_at)}</span>
            </div>
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              <a className="btn btn-ghost btn-sm" href={`/api/booklets/${b.id}`}>تحميل</a>
              <ActionForm action={deleteBookletAction} submit="حذف" submitClass="btn btn-ghost btn-sm" confirm={`حذف «${b.title}» نهائياً؟`}>
                <input type="hidden" name="id" value={b.id} />
              </ActionForm>
            </div>
            <details>
              <summary style={{ cursor: "pointer", minHeight: 36 }}>تعديل</summary>
              <ActionForm action={saveBookletAction}>
                <input type="hidden" name="id" value={b.id} />
                <div className="field"><label htmlFor={`bt-${b.id}`}>اسم الكتيب</label><input id={`bt-${b.id}`} name="title" required maxLength={120} defaultValue={b.title} /></div>
                <div className="field"><label htmlFor={`bd-${b.id}`}>وصف قصير</label><input id={`bd-${b.id}`} name="description" maxLength={300} defaultValue={b.description ?? ""} /></div>
                <label className="row" style={{ gap: 8 }}><input type="checkbox" name="published" defaultChecked={b.published} /> يظهر للمتدربين</label>
              </ActionForm>
            </details>
          </div>
        ))}
      </section>
    </div>
  );
}
