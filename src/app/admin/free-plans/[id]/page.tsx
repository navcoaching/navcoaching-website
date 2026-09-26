import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import { saveFreePlanAction } from "@/app/actions/admin";

type Plan = { id: string; slug: string; title: string; summary: string; audience: string | null; image_id: string | null; status: string; sort: number; file_size: number | null; file_updated_at: string | null };

export default async function EditFreePlan({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ created?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { created } = await searchParams;
  const isNew = id === "new";
  if (!isNew && !/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { plan, media, requests } = await withUser(coach.id, async (tx) => ({
    plan: isNew ? null : ((await tx.query(
      `SELECT id, slug, title, summary, audience, image_id, status, sort, file_size, file_updated_at FROM free_plans WHERE id = $1`, [id])).rows[0] as Plan | undefined),
    media: (await tx.query(`SELECT id, alt, usage FROM media_assets WHERE approved ORDER BY (usage = 'free_plan') DESC, created_at DESC`)).rows as { id: string; alt: string; usage: string }[],
    requests: isNew ? [] : (await tx.query(
      `SELECT u.name, u.email, r.created_at FROM free_plan_requests r JOIN "user" u ON u.id = r.user_id WHERE r.plan_id = $1 ORDER BY r.created_at DESC LIMIT 50`, [id])).rows,
  }));
  if (!isNew && !plan) notFound();

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 820 }}>
      <nav className="small"><Link href="/admin/free-plans">الجداول المجانية</Link> / {plan?.title ?? "جدول جديد"}</nav>
      <h1>{isNew ? "جدول مجاني جديد" : "تعديل الجدول"}</h1>
      {created && <p className="alert ok" role="status">تم إنشاء الجدول.</p>}
      <div className="card">
        <ActionForm action={saveFreePlanAction} submit={isNew ? "إنشاء الجدول" : "حفظ التعديلات"}>
          <input type="hidden" name="id" value={plan?.id ?? ""} />
          <div className="field"><label htmlFor="fp-title">اسم الجدول <span className="req">*</span></label>
            <input id="fp-title" name="title" type="text" required minLength={3} maxLength={120} defaultValue={plan?.title} /></div>
          <div className="field"><label htmlFor="fp-slug">رابط الصفحة (بالإنجليزي) <span className="req">*</span></label>
            <input id="fp-slug" name="slug" type="text" dir="ltr" required maxLength={60} pattern="[a-z0-9]+(-[a-z0-9]+)*" placeholder="home-beginner" defaultValue={plan?.slug} />
            <span className="hint">يظهر هكذا: navcoaching.com/free-plans/<bdi dir="ltr">home-beginner</bdi> — حروف صغيرة وأرقام وشرطات. تغييره بعد النشر يكسر الروابط القديمة.</span></div>
          <div className="field"><label htmlFor="fp-summary">وصف مختصر <span className="req">*</span></label>
            <textarea id="fp-summary" name="summary" required minLength={10} maxLength={600} defaultValue={plan?.summary} />
            <span className="hint">لمن يناسب الجدول وماذا يحتوي. تجنبي الوعود بنتائج مضمونة.</span></div>
          <div className="grid g2">
            <div className="field"><label htmlFor="fp-audience">الفئة المناسبة (اختياري)</label>
              <input id="fp-audience" name="audience" type="text" maxLength={120} placeholder="مثال: مبتدئ · تمارين في البيت" defaultValue={plan?.audience ?? ""} /></div>
            <div className="field"><label htmlFor="fp-image">صورة الغلاف (اختياري)</label>
              <select id="fp-image" name="image_id" defaultValue={plan?.image_id ?? ""}>
                <option value="">أيقونة افتراضية</option>
                {media.map((m) => <option key={m.id} value={m.id}>{m.alt}{m.usage === "free_plan" ? " (جدول مجاني)" : ""}</option>)}
              </select>
              <span className="hint">ارفعي الصور من <Link href="/admin/media">الصور</Link> واختاري الاستخدام «جدول مجاني».</span></div>
          </div>
          <div className="field"><label htmlFor="fp-file">ملف PDF {isNew && <span className="req">*</span>}</label>
            <input id="fp-file" name="file" type="file" accept="application/pdf,.pdf" required={isNew} />
            <span className="hint">
              PDF فقط، حتى 5 ميجابايت. {plan?.file_size ? <>الملف الحالي: {(plan.file_size / 1024 / 1024).toFixed(1)} م.ب{plan.file_updated_at ? ` · ${fmtDate(plan.file_updated_at)}` : ""}. رفع ملف جديد يستبدله لكل من طلب الجدول.</> : "لا يوجد ملف بعد."}
            </span></div>
          <div className="grid g2">
            <fieldset className="field"><legend>الحالة</legend>
              <label className="check"><input type="radio" name="status" value="published" defaultChecked={plan?.status === "published"} /><span>منشور (يظهر في الموقع)</span></label>
              <label className="check"><input type="radio" name="status" value="hidden" defaultChecked={!plan || plan.status !== "published"} /><span>مخفي</span></label>
            </fieldset>
            <div className="field"><label htmlFor="fp-sort">الترتيب</label><input id="fp-sort" name="sort" type="number" defaultValue={plan?.sort ?? 0} style={{ maxWidth: 120 }} /></div>
          </div>
        </ActionForm>
      </div>
      {!isNew && (
        <div className="card stack">
          <h2 style={{ fontSize: 18 }}>من طلب الجدول ({requests.length}{requests.length === 50 ? "+" : ""})</h2>
          {requests.length === 0 ? <p className="muted small">لا توجد طلبات بعد.</p> : (
            <ul className="small" style={{ margin: 0, paddingInlineStart: 18 }}>
              {requests.map((r, i) => <li key={i}>{r.name && !String(r.name).includes("@") ? r.name : "—"} · <bdi dir="ltr">{r.email}</bdi> · {fmtDate(r.created_at)}</li>)}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
