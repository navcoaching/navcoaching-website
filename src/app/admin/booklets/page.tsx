import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import { deleteBookletAction, saveBookletAction, uploadBookletAction } from "@/app/actions/booklets";
import FilePicker from "@/components/FilePicker";

export const metadata = { title: "الكتيبات" };

type Row = { id: string; title: string; description: string | null; file_size: number; published: boolean; created_at: string; price_halalas: number | null; for_sale: boolean; sold: number };

/** الكتيبات: ملفات PDF لمشتركي باقات المتابعة في «حسابي»، وتُباع منفردة لغيرهم في /booklets */
export default async function AdminBooklets() {
  const coach = await requireCoach();
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT b.id, b.title, b.description, b.file_size, b.published, b.created_at,
            o.price_halalas, coalesce(p.status = 'published', false) AS for_sale,
            (SELECT count(*)::int FROM orders x WHERE x.product_id = p.id AND x.status IN ('preparing','active','delivered','completed')) AS sold
       FROM booklets b LEFT JOIN products p ON p.booklet_id = b.id LEFT JOIN product_offers o ON o.product_id = p.id AND o.active
      ORDER BY b.sort, b.created_at`)).rows as Row[]);
  const sar = (h: number | null) => (h ? String(h / 100) : "");
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 900 }}>
      <h1>الكتيبات</h1>
      <p className="muted">تظهر في «حسابي» لمشتركي باقات المتابعة (الأساسية، المكثفة، المتقدمة)، وتبقى لهم بعد انتهاء الاشتراك. والكتيب اللي له «سعر البيع» ينعرض في صفحة <a href="/booklets" target="_blank" rel="noopener">الكتيبات</a> لغير المشتركين: يشترونه بتحويل بنكي، وبعد تأكيد الدفع من صفحة الطلب يفتح لهم تلقائياً. الملفات في التخزين الخاص، وما يحمّلها إلا صاحب الحق وهو مسجّل الدخول.</p>

      <section className="card stack" data-testid="booklet-upload">
        <h2 style={{ fontSize: 19 }}>رفع كتيب</h2>
        <ActionForm action={uploadBookletAction} submit="رفع الكتيب" resetOnSuccess>
          <div className="field"><label htmlFor="bk-title">اسم الكتيب</label><input id="bk-title" name="title" required maxLength={120} /></div>
          <div className="field"><label htmlFor="bk-desc">وصف قصير (اختياري)</label><input id="bk-desc" name="description" maxLength={300} /></div>
          <div className="field"><label htmlFor="bk-price">سعر البيع لغير المشتركين (ريال، اختياري)</label><input id="bk-price" name="price" inputMode="decimal" dir="ltr" placeholder="مثل 49" style={{ maxWidth: 180 }} /><span className="hint">فاضي = للمشتركين فقط، وما ينعرض للبيع.</span></div>
          <div className="field"><label htmlFor="bk-file">ملف PDF</label><FilePicker id="bk-file" name="file" accept="application/pdf,.pdf" required hint="PDF حتى 5 ميجابايت" /></div>
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
              <span><b>{b.title}</b> <span className={`status ${b.published ? "ok" : "muted"}`}>{b.published ? "ظاهر" : "مخفي"}</span>{" "}
                {b.for_sale ? <span className="status ok" data-testid="booklet-for-sale">للبيع · <bdi className="num">{sar(b.price_halalas)}</bdi> ر.س</span> : <span className="status muted">للمشتركين فقط</span>}
                {b.sold > 0 && <span className="small muted"> · مبيعات <bdi className="num">{b.sold}</bdi></span>}</span>
              <span className="small muted">PDF · <span className="num">{(b.file_size / 1024 / 1024).toFixed(1)}</span> م.ب · {fmtDate(b.created_at)}</span>
            </div>
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              <a className="btn btn-ghost btn-sm" href={`/api/booklets/${b.id}`}>تحميل</a>
              <ActionForm action={deleteBookletAction} submit="حذف" submitClass="btn btn-ghost btn-sm" confirm={b.sold ? `«${b.title}» مشترى ${b.sold} مرة، وحذفه يقفله عن المشترين. الحذف نهائياً؟` : `حذف «${b.title}» نهائياً؟`}>
                <input type="hidden" name="id" value={b.id} />
              </ActionForm>
            </div>
            <details>
              <summary style={{ cursor: "pointer", minHeight: 36 }}>تعديل</summary>
              <ActionForm action={saveBookletAction}>
                <input type="hidden" name="id" value={b.id} />
                <div className="field"><label htmlFor={`bt-${b.id}`}>اسم الكتيب</label><input id={`bt-${b.id}`} name="title" required maxLength={120} defaultValue={b.title} /></div>
                <div className="field"><label htmlFor={`bd-${b.id}`}>وصف قصير</label><input id={`bd-${b.id}`} name="description" maxLength={300} defaultValue={b.description ?? ""} /></div>
                <div className="field"><label htmlFor={`bp-${b.id}`}>سعر البيع لغير المشتركين (ريال)</label><input id={`bp-${b.id}`} name="price" inputMode="decimal" dir="ltr" defaultValue={sar(b.price_halalas)} placeholder="فاضي = للمشتركين فقط" style={{ maxWidth: 180 }} /></div>
                <label className="row" style={{ gap: 8 }}><input type="checkbox" name="published" defaultChecked={b.published} /> يظهر للمتدربين</label>
              </ActionForm>
            </details>
          </div>
        ))}
      </section>
    </div>
  );
}
