import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getProduct, getProducts, getSettings } from "@/lib/data";
import { CATEGORY_LABEL, riyals, shortName } from "@/lib/format";
import { timelineSteps } from "@/lib/status";
import { IconArrow } from "@/components/Icons";
import { fromPrice } from "@/components/ProductCard";
import { productDescription } from "@/lib/seo";
import JsonLd, { siteUrl } from "@/components/JsonLd";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

export async function generateStaticParams() {
  try { return (await getProducts()).map((p) => ({ slug: p.slug })); } catch { return []; }
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const p = await getProduct((await params).slug);
  return p ? { title: p.name, description: productDescription(p) } : { title: "غير موجود" };
}

export default async function ProductPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const [p, s] = await Promise.all([getProduct(slug), getSettings()]);
  if (!p) notFound();
  const offers = p.offers.filter((o) => o.active);
  const steps = timelineSteps(p.category, false);
  const price = fromPrice(p);
  // توفير العرض الأطول مقارنة بسعر الشهر الواحد (يُعرض فقط إذا كان فيه عرض شهري للمقارنة)
  const monthly = offers.find((o) => o.months === 1);
  const saving = (o: (typeof offers)[number]) => (monthly && o.months > 1 ? monthly.price_halalas * o.months - o.price_halalas : 0);

  const url = `${siteUrl()}/programs/${p.slug}`;
  return (
    <div className="pub">
      {!p.is_demo && offers.length > 0 && (
        <JsonLd data={{ "@context": "https://schema.org", "@type": "Service", name: p.name, description: p.audience, url, provider: { "@type": "Organization", name: "Nav Coaching", url: siteUrl() },
          areaServed: "SA", offers: offers.map((o) => ({ "@type": "Offer", name: o.label, price: (o.price_halalas / 100).toFixed(2), priceCurrency: o.currency || "SAR", url })) }} />
      )}
      <section className="page-hero">
        <div className="wrap">
          <nav className="small crumbs" aria-label="مسار التنقل"><Link href="/programs">البرامج</Link> / <span>{CATEGORY_LABEL[p.category]}</span></nav>
          <div className="row" style={{ marginTop: 14 }}>
            {p.recommended && <span className="tag">الأكثر طلباً</span>}
            {p.is_demo && <span className="tag demo">منتج تجريبي — غير معروض للبيع</span>}
          </div>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 10 }}>{p.name}</h1>
          <p className="lead">{p.audience}</p>
          {price && offers.length > 0 && (
            <div className="hero-buy" data-testid="hero-buy">
              <p className="price"><b className="num">{price.value.replace(" ر.س", "")}</b><span>ر.س {price.unit}</span></p>
              <a href="#offers" className="btn">الاشتراك <IconArrow size={18} className="arrow" /></a>
            </div>
          )}
        </div>
      </section>

      <section className="section tight">
        <div className="wrap account-layout product-layout">
          <div className="stack" style={{ ["--space" as string]: "22px" }}>
            <div className="card">
              <h2 style={{ fontSize: 22, marginBottom: 16 }}>ماذا يشمل؟</h2>
              <ul className="checklist">
                {p.items.map((it) => <li key={it.text} className={it.included ? "" : "no"}>{it.text}</li>)}
              </ul>
              {p.note && <p className="small muted" style={{ marginTop: 14 }}>{p.note}</p>}
            </div>
            <div className="card">
              <dl className="kv">
                {p.delivery && (<><dt>التسليم والمتابعة</dt><dd>{p.delivery}</dd></>)}
                <dt>المدة</dt><dd>{offers.map((o) => o.label).join(" أو ")}</dd>
                {p.requirements && (<><dt>المطلوب قبل البدء</dt><dd>{p.requirements}</dd></>)}
                <dt>مدة الرد</dt><dd>{s.response_time}</dd>
                {p.policy_note && (<><dt>الدفع والاسترجاع</dt><dd>{p.policy_note} <Link href="/policies#refund">التفاصيل</Link></dd></>)}
              </dl>
            </div>
            <div className="card flat">
              <h2 style={{ fontSize: 20, marginBottom: 14 }}>وش يصير بعد الطلب؟</h2>
              <ol className="timeline">
                {steps.map((st) => <li key={st.key}>{st.label}</li>)}
              </ol>
              <p className="small muted">الطلب لا يُعتبر مدفوعاً إلا بعد التحقق من وصول التحويل.</p>
            </div>
          </div>

          <aside className="card offers-card" id="offers" aria-label="الاشتراك">
            <h2 style={{ fontSize: 20 }}>مدة الاشتراك</h2>
            <div className="stack" style={{ marginTop: 14 }}>
              {offers.map((o) => (
                <div key={o.sku} className="card flat" style={{ padding: 16 }}>
                  <div className="row" style={{ justifyContent: "space-between" }}>
                    <b>{o.label}</b>
                    <span className="price"><b className="num" style={{ fontSize: 26 }}>{riyals(o.price_halalas).replace(" ر.س", "")}</b><span>ر.س</span></span>
                  </div>
                  {o.months > 1 && <p className="small muted">≈ {riyals(Math.round(o.price_halalas / o.months))} شهرياً{saving(o) > 0 && <> · <b className="save">توفير {riyals(saving(o))}</b></>}</p>}
                  <Link href={`/checkout/${o.sku}`} className="btn btn-block" style={{ marginTop: 12 }}>
                    الاشتراك في {shortName(p.name)} — {o.label} <IconArrow size={18} className="arrow" />
                  </Link>
                </div>
              ))}
            </div>
            <p className="small muted" style={{ marginTop: 14 }}>{s.prices_note} خصم 10% للطلاب (يُطلب إثبات بسيط).</p>
          </aside>
        </div>
      </section>
      {/* شريط ثابت أسفل الشاشة على الجوال: السعر وزر الاشتراك في متناول اليد أثناء القراءة */}
      {price && offers.length > 0 && (
        <div className="buy-bar" data-testid="buy-bar">
          <span className="price"><b className="num">{price.value.replace(" ر.س", "")}</b><span>ر.س {price.unit}</span></span>
          <a href="#offers" className="btn btn-sm">الاشتراك</a>
        </div>
      )}
    </div>
  );
}
