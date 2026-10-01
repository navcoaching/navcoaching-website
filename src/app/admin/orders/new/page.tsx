import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { riyals } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import { createManualOrderAction } from "@/app/actions/admin";

type Offer = { sku: string; label: string; price_halalas: number; active: boolean; product: string; category: string; status: string };

/** إضافة برنامج لمتدرب يدوياً (بدون استبيان الموقع) */
export default async function NewManualOrder({ searchParams }: { searchParams: Promise<{ email?: string; name?: string }> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const { offers, member } = await withUser(coach.id, async (tx) => ({
    offers: (await tx.query(
      `SELECT o.sku, o.label, o.price_halalas, o.active, p.name AS product, p.category, p.status
         FROM product_offers o JOIN products p ON p.id = o.product_id
        WHERE NOT p.is_demo ORDER BY p.sort, o.sort`)).rows as Offer[],
    member: sp.email ? (await tx.query(`SELECT name, email, phone FROM "user" WHERE lower(email) = lower($1)`, [sp.email])).rows[0] : undefined,
  }));
  const groups = [...new Set(offers.map((o) => o.product))];

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 760 }}>
      <nav className="small"><Link href="/admin/orders">الطلبات</Link> / طلب يدوي</nav>
      <h1>إضافة برنامج لمتدرب يدوياً</h1>
      <p className="muted">للمتدربين اللي اتفقتِ معهم خارج الموقع (واتساب مثلاً) بدون تعبئة الاستبيان. إذا ما عنده حساب يُنشأ له حساب بهذا البريد، ويدخل لاحقاً برمز يصله على نفس البريد ويشوف برنامجه وملفاته.</p>
      <div className="card">
        <ActionForm action={createManualOrderAction} submit="إنشاء الطلب">
          <div className="grid g2">
            <div className="field"><label htmlFor="m-email">بريد المتدرب <span className="req">*</span></label>
              <input id="m-email" name="email" type="email" dir="ltr" required maxLength={200} defaultValue={member?.email ?? sp.email ?? ""} /></div>
            <div className="field"><label htmlFor="m-name">الاسم <span className="req">*</span></label>
              <input id="m-name" name="name" type="text" required minLength={2} maxLength={80} defaultValue={member?.name && !member.name.includes("@") ? member.name : sp.name ?? ""} /></div>
            <div className="field"><label htmlFor="m-phone">الجوال (اختياري)</label>
              <input id="m-phone" name="phone" type="tel" dir="ltr" maxLength={20} placeholder="+9665XXXXXXXX" defaultValue={member?.phone ?? ""} /></div>
            <div className="field"><label htmlFor="m-sku">الباقة والمدة <span className="req">*</span></label>
              <select id="m-sku" name="sku" required defaultValue="">
                <option value="" disabled>اختاري…</option>
                {groups.map((g) => (
                  <optgroup key={g} label={g}>
                    {offers.filter((o) => o.product === g).map((o) => (
                      <option key={o.sku} value={o.sku}>{o.product} — {o.label} ({riyals(o.price_halalas)}){o.active && o.status === "published" ? "" : " · غير معروض بالموقع"}</option>
                    ))}
                  </optgroup>
                ))}
              </select></div>
          </div>
          <fieldset className="field">
            <legend>الحالة <span className="req">*</span></legend>
            <label className="check"><input type="radio" name="status" value="active" defaultChecked /><span>البرنامج نشط الآن (باقات المتابعة) — يبدأ الاشتراك اليوم</span></label>
            <label className="check"><input type="radio" name="status" value="delivered" /><span>تم التسليم (جداول بدون متابعة)</span></label>
            <label className="check"><input type="radio" name="status" value="preparing" /><span>مدفوع وقيد الإعداد</span></label>
            <label className="check"><input type="radio" name="status" value="awaiting_payment" /><span>بانتظار الدفع (يظهر له الحساب البنكي ورفع الإيصال)</span></label>
            <span className="hint">«نشط» لباقات المتابعة فقط، و«تم التسليم» للجداول فقط.</span>
          </fieldset>
          <div className="grid g2">
            <div className="field"><label htmlFor="m-amount">المبلغ بالريال (اتركيه فارغاً = سعر الباقة، 0 = مجاني)</label>
              <input id="m-amount" name="amount" type="number" min={0} step="0.01" inputMode="decimal" /></div>
            <div className="field"><label htmlFor="m-note">ملاحظة تظهر للمتدرب في تحديثات الطلب (اختياري)</label>
              <input id="m-note" name="note" type="text" maxLength={500} /></div>
          </div>
          <label className="check"><input type="checkbox" name="notify" defaultChecked /><span>أرسلي له بريداً بأن برنامجه أُضيف لحسابه</span></label>
        </ActionForm>
      </div>
    </div>
  );
}
