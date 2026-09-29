import type { Metadata } from "next";
import { notFound } from "next/navigation";
import CheckoutForm from "./CheckoutForm";
import { requireUser } from "@/lib/session";
import { getOfferBySku, getProducts, getSettings } from "@/lib/data";
import { CATEGORY_LABEL, riyals } from "@/lib/format";
import { parseConfig } from "@/lib/intake-config";

export const metadata: Metadata = { title: "استبيان المتدرب", robots: { index: false } };

export default async function Checkout({ params }: { params: Promise<{ sku: string }> }) {
  const { sku } = await params;
  const user = await requireUser(`/checkout/${sku}`);
  const [found, products, s] = await Promise.all([getOfferBySku(sku), getProducts(), getSettings()]);
  if (!found) notFound();

  const offers = products.flatMap((p) => p.offers.filter((o) => o.active).map((o) => ({
    sku: o.sku, label: `${p.name} — ${o.label}`, group: CATEGORY_LABEL[p.category], price: riyals(o.price_halalas),
  })));

  return (
    <>
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">استبيان المتدرب</span>
          <h1 style={{ fontSize: "clamp(28px,5vw,44px)", marginTop: 12 }}>خلّني أعرفك عشان أصمم برنامجك</h1>
          <p className="lead">5 خطوات قصيرة، وبعدها يظهر لك رقم طلبك وبيانات الدفع. إجاباتك تُحفظ على جهازك أثناء التعبئة (عدا البيانات الصحية والقياسات).</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap account-layout">
          <div className="card"><CheckoutForm sku={sku} offers={offers} defaultName={user.name.includes("@") ? "" : user.name} responseTime={s.response_time} intake={parseConfig(s.intake_questions)} /></div>
          <aside className="card flat stack">
            <span className="eyebrow">طلبك</span>
            <h2 style={{ fontSize: 20 }}>{found.product.name}</h2>
            <p>{found.offer.label} · <b className="num">{riyals(found.offer.price_halalas)}</b></p>
            <p className="small muted">تقدر تغيّر الباقة من الخطوة الأولى. الدفع بتحويل بنكي بعد إرسال الاستبيان، ولا يُعتبر الطلب مدفوعاً إلا بعد التحقق من وصول المبلغ.</p>
            <p className="small muted">مسجّل الدخول بـ <bdi dir="ltr">{user.email}</bdi></p>
          </aside>
        </div>
      </section>
    </>
  );
}
