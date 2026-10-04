import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getProduct, getProducts, getSettings } from "@/lib/data";
import { CATEGORY_LABEL, riyals, shortName } from "@/lib/format";
import { timelineSteps } from "@/lib/status";
import { IconArrow } from "@/components/Icons";
import JsonLd, { siteUrl } from "@/components/JsonLd";

export const revalidate = 300;

export async function generateStaticParams() {
  try { return (await getProducts()).map((p) => ({ slug: p.slug })); } catch { return []; }
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const p = await getProduct((await params).slug);
  return p ? { title: p.name, description: p.audience } : { title: "غير موجود" };
}

export default async function ProductPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const [p, s] = await Promise.all([getProduct(slug), getSettings()]);
  if (!p) notFound();
  const offers = p.offers.filter((o) => o.active);
  const steps = timelineSteps(p.category, false);

  const url = `${siteUrl()}/programs/${p.slug}`;
  return (
    <>
      {!p.is_demo && offers.length > 0 && (
        <JsonLd data={{ "@context": "https://schema.org", "@type": "Service", name: p.name, description: p.audience, url, provider: { "@type": "Organization", name: "Nav Coaching", url: siteUrl() },
          areaServed: "SA", offers: offers.map((o) => ({ "@type": "Offer", name: o.label, price: (o.price_halalas / 100).toFixed(2), priceCurrency: o.currency || "SAR", url })) }} />
      )}
      <section className="page-hero">
        <div className="wrap">
          <nav className="small" aria-label="مسار التنقل"><Link href="/programs" style={{ color: "var(--on-dark-muted)" }}>البرامج</Link> / <span>{CATEGORY_LABEL[p.category]}</span></nav>
          <div className="row" style={{ marginTop: 14 }}>
            {p.recommended && <span className="tag">الأكثر طلباً</span>}
            {p.is_demo && <span className="tag demo">منتج تجريبي — غير معروض للبيع</span>}
          </div>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 10 }}>{p.name}</h1>
          <p className="lead">{p.audience}</p>
        </div>
      </section>

      <section className="section tight">
        <div className="wrap account-layout">
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
                <dt>لمن يناسب</dt><dd>{p.audience}</dd>
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
                {steps.map((st) => <li key={st.key} className="done">{st.label}</li>)}
              </ol>
              <p className="small muted">الطلب لا يُعتبر مدفوعاً إلا بعد التحقق من وصول التحويل.</p>
            </div>
          </div>

          <aside className="card" style={{ position: "sticky", top: "calc(var(--header-h) + 16px)" }} aria-label="الاشتراك">
            <h2 style={{ fontSize: 20 }}>اختر المدة</h2>
            <div className="stack" style={{ marginTop: 14 }}>
              {offers.map((o) => (
                <div key={o.sku} className="card flat" style={{ padding: 16 }}>
                  <div className="row" style={{ justifyContent: "space-between" }}>
                    <b>{o.label}</b>
                    <span className="price"><b className="num" style={{ fontSize: 26 }}>{riyals(o.price_halalas).replace(" ر.س", "")}</b><span>ر.س</span></span>
                  </div>
                  {o.months > 1 && <p className="small muted">≈ {riyals(Math.round(o.price_halalas / o.months))} شهرياً</p>}
                  <Link href={`/checkout/${o.sku}`} className="btn btn-block" style={{ marginTop: 12 }}>
                    اشترك في {shortName(p.name)} — {o.label} <IconArrow size={18} className="arrow" />
                  </Link>
                </div>
              ))}
            </div>
            <p className="small muted" style={{ marginTop: 14 }}>{s.prices_note} خصم 10% للطلاب (يُطلب إثبات بسيط).</p>
          </aside>
        </div>
      </section>
    </>
  );
}
