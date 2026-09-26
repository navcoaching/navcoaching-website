import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import { updateMediaAction, uploadMediaAction } from "@/app/actions/admin";

const USAGE: Record<string, string> = { hero: "الواجهة", about: "عن المدربة", gallery: "معرض", product: "منتج", free_plan: "جدول مجاني" };

export default async function AdminMedia() {
  const coach = await requireCoach();
  const rows = await withUser(coach.id, async (tx) => (await tx.query("SELECT * FROM media_assets ORDER BY created_at DESC")).rows);
  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>الصور</h1>
      <p className="alert warn small">ارفعي فقط صوراً مملوكة لك أو مرخّصة للاستخدام التجاري. لا تنشري صور متدربين أو نتائجهم إلا بإذن صريح مكتوب. الصور لا تظهر في الموقع قبل «اعتماد النشر».</p>
      <ActionForm action={uploadMediaAction} submit="رفع الصورة" className="form card">
        <div className="field"><label>الصورة (JPG / PNG / WebP حتى 5MB)</label><input name="file" type="file" accept="image/jpeg,image/png,image/webp" required /></div>
        <div className="grid g2">
          <div className="field"><label>وصف الصورة *</label><input name="alt" type="text" required placeholder="مثال: بار أولمبي وأقراص أوزان في النادي" /></div>
          <div className="field"><label>الاستخدام</label><select name="usage" defaultValue="gallery">{Object.entries(USAGE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
        </div>
        <div className="field"><label>مصدر الصورة / إذن النشر *</label><input name="rights_note" type="text" required placeholder="تصويري الشخصي في النادي، أو: ترخيص من …" /></div>
        <label className="check"><input type="checkbox" name="approved" /><span>أؤكد أن لدي حق نشر هذه الصورة، واعتمدها للنشر الآن.</span></label>
      </ActionForm>
      <div className="grid g3">
        {rows.map((m) => (
          <div key={m.id} className="card stack">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={`/api/files/media/${m.id}`} alt={m.alt} loading="lazy" style={{ borderRadius: 12, aspectRatio: "4/3", objectFit: "cover", width: "100%" }} />
            <p className="small"><b>{m.alt}</b><br />{USAGE[m.usage]} · {fmtDate(m.created_at)}<br /><span className="muted">المصدر: {m.rights_note}</span></p>
            <span className={`status ${m.approved ? "ok" : "muted"}`}>{m.approved ? "معتمدة للنشر" : "غير منشورة"}</span>
            <div className="row">
              <ActionForm action={updateMediaAction} submit={m.approved ? "إيقاف النشر" : "اعتماد النشر"} submitClass="btn btn-ghost btn-sm" className="row">
                <input type="hidden" name="id" value={m.id} /><input type="hidden" name="op" value={m.approved ? "unapprove" : "approve"} />
              </ActionForm>
              <ActionForm action={updateMediaAction} submit="حذف" submitClass="btn btn-danger btn-sm" className="row" confirm="حذف الصورة نهائياً؟">
                <input type="hidden" name="id" value={m.id} /><input type="hidden" name="op" value="delete" />
              </ActionForm>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
