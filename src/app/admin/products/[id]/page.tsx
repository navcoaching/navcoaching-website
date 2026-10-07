import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import { saveProductAction } from "@/app/actions/admin";

type Offer = { id: string; sku: string; label: string; months: number; price_halalas: number; active: boolean };

export default async function EditProduct({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ saved?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { saved } = await searchParams;
  const isNew = id === "new";
  const { p, media } = await withUser(coach.id, async (tx) => ({
    p: isNew ? null : (await tx.query(
      `SELECT p.*, coalesce(json_agg(o ORDER BY o.sort) FILTER (WHERE o.id IS NOT NULL), '[]') offers
         FROM products p LEFT JOIN product_offers o ON o.product_id = p.id WHERE p.id = $1::uuid GROUP BY p.id`,
      [/^[0-9a-f-]{36}$/.test(id) ? id : "00000000-0000-0000-0000-000000000000"])).rows[0],
    media: (await tx.query("SELECT id, alt FROM media_assets WHERE approved ORDER BY created_at DESC")).rows as { id: string; alt: string }[],
  }));
  if (!isNew && !p) notFound();
  const offers: Offer[] = p?.offers ?? [];
  const rows = [...offers, { id: "", sku: "", label: "", months: 0, price_halalas: 0, active: true }, { id: "", sku: "", label: "", months: 0, price_halalas: 0, active: true }];
  const items = (p?.items ?? []).map((it: { text: string; included: boolean }) => (it.included ? it.text : `- ${it.text}`)).join("\n");

  return (
    <div className="stack">
      <nav className="small"><Link href="/admin/products">المنتجات</Link> / {p?.name ?? "جديد"}</nav>
      <h1>{isNew ? "منتج جديد" : p.name}</h1>
      {saved && <p className="alert ok">تم إنشاء المنتج.</p>}
      <ActionForm action={saveProductAction} submit="حفظ المنتج" submitClass="btn">
        <input type="hidden" name="id" value={p?.id ?? ""} />
        <div className="card stack">
          <div className="grid g2">
            <div className="field"><label>الاسم *</label><input name="name" type="text" defaultValue={p?.name} required /></div>
            <div className="field"><label>الرابط (إنجليزي) *</label><input name="slug" type="text" dir="ltr" defaultValue={p?.slug} required pattern="[a-z0-9-]{2,60}" /></div>
            <div className="field"><label>القسم</label>
              <select name="category" defaultValue={p?.category ?? "follow"}><option value="follow">مع متابعة</option><option value="files">ملفات بدون متابعة</option><option value="consult">استشارات</option></select>
              <span className="hint">يحدد مسار الطلب: المتابعة ← «نشط»، الملفات ← «تم التسليم»، الاستشارة ← «تمت الجلسة».</span>
            </div>
            <div className="field"><label>الحالة</label>
              <select name="status" defaultValue={p?.status ?? "draft"}><option value="draft">مسودة (مخفي)</option><option value="published">منشور</option><option value="archived">مؤرشف</option></select>
            </div>
          </div>
          <div className="field"><label>لمن يناسب</label><input name="audience" type="text" defaultValue={p?.audience} /></div>
          <div className="field"><label>ماذا يشمل (سطر لكل عنصر، وابدئي السطر بـ «-» لما لا يشمله)</label><textarea name="items" defaultValue={items} style={{ minHeight: 180 }} /></div>
          <div className="field"><label>ملاحظة قصيرة</label><input name="note" type="text" defaultValue={p?.note ?? ""} /></div>
          <div className="field"><label>التسليم والمتابعة</label><textarea name="delivery" defaultValue={p?.delivery ?? ""} /></div>
          <div className="field"><label>المطلوب من العميل قبل البدء</label><textarea name="requirements" defaultValue={p?.requirements ?? ""} /></div>
          <div className="field"><label>سياسة الدفع/الاسترجاع الخاصة بالمنتج</label><textarea name="policy_note" defaultValue={p?.policy_note ?? ""} /></div>
          <div className="grid g2">
            <div className="field"><label>الترتيب</label><input name="sort" type="number" min={0} defaultValue={p?.sort ?? 0} /></div>
            <div className="field"><label>صورة المنتج (من الصور المعتمدة)</label>
              <select name="image_id" defaultValue={p?.image_id ?? ""}><option value="">بدون صورة</option>{media.map((m) => <option key={m.id} value={m.id}>{m.alt}</option>)}</select>
            </div>
          </div>
          <label className="check"><input type="checkbox" name="recommended" defaultChecked={p?.recommended} /><span>شارة «الأكثر طلباً»</span></label>
          <label className="check"><input type="checkbox" name="video_review" defaultChecked={p?.video_review} /><span>🎥 مراجعة أسبوعية بالفيديو (تظهر لكِ خانة رابط فيديو عند الرد على مراجعات مشتركي الباقة)</span></label>
          <div className="field"><label htmlFor="app-addon">خدمة إضافية في تطبيق الجوال</label>
            <select id="app-addon" name="app_addon" defaultValue={p?.app_addon ?? ""}>
              <option value="">لا (منتج عادي)</option>
              <option value="program_review">«راجعي جدولي»: يرسل برنامجه وسجل 4 أسابيع من التطبيق</option>
              <option value="form_check">«تصحيح أداء تمرين»: يرسل مقطع فيديو قصير</option>
              <option value="meal_library">«وجباتي»: يفتح وجبات قوالب التغذية في التطبيق</option>
            </select>
            <span className="hint">تظهر في التطبيق ضمن «خدمات الكوتش» إذا كان المنتج منشوراً. خدمة واحدة منشورة لكل نوع. اختاري التصنيف «استشارة».</span></div>
        </div>
        <div className="card stack">
          <h2 style={{ fontSize: 18 }}>المدد والأسعار</h2>
          <p className="small muted">رمز العرض يظهر في رابط الشراء. اتركي السطر فارغاً إذا لا تحتاجينه. المدة بالأشهر: 0 للدفعة الواحدة.</p>
          <div className="table-wrap">
            <table className="t">
              <thead><tr><th>رمز العرض</th><th>الاسم</th><th>الأشهر</th><th>السعر (ر.س)</th><th>مفعّل</th></tr></thead>
              <tbody>
                {rows.map((o, i) => (
                  <tr key={o.id || `n${i}`}>
                    <td><input type="hidden" name="offer_id" value={o.id} /><input name="offer_sku" type="text" dir="ltr" defaultValue={o.sku} aria-label="رمز العرض" /></td>
                    <td><input name="offer_label" type="text" defaultValue={o.label} aria-label="اسم العرض" /></td>
                    <td><input name="offer_months" type="number" min={0} max={24} defaultValue={o.months} aria-label="الأشهر" /></td>
                    <td><input name="offer_price" type="number" min={0} step="0.01" defaultValue={o.price_halalas / 100 || ""} aria-label="السعر" /></td>
                    <td><input type="checkbox" name="offer_active" value={String(i)} defaultChecked={o.active} aria-label="مفعّل" style={{ width: 22, height: 22 }} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </ActionForm>
    </div>
  );
}
