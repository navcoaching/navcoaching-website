import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getProduct, getProducts, getSettings } from "@/lib/data";
import { categoryLabel, CURRENCY, offerLabel, priceNum, riyals, shortName, waIntro, waLink } from "@/lib/format";
import { timelineSteps } from "@/lib/status";
import { IconArrow, IconWhatsApp } from "@/components/Icons";
import { fromPrice } from "@/components/ProductCard";
import { productDescription } from "@/lib/seo";
import JsonLd, { siteUrl } from "@/components/JsonLd";
import { href, isLang, LANGS, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string; slug: string }> };

export async function generateStaticParams() {
  try { return (await getProducts()).flatMap((p) => LANGS.map((lang) => ({ lang, slug: p.slug }))); } catch { return []; }
}

export async function generateMetadata({ params }: P): Promise<Metadata> {
  const { lang: raw, slug } = await params;
  const lang: Lang = isLang(raw) ? raw : "ar";
  const p = await getProduct(slug, lang);
  return p ? pageMeta(lang, `/programs/${p.slug}`, { title: p.name, description: productDescription(p, lang) }) : { title: t(lang).product.notFound };
}

export default async function ProductPage({ params }: P) {
  const { lang: raw, slug } = await params;
  const lang: Lang = isLang(raw) ? raw : "ar";
  const u = t(lang).product;
  const [p, s] = await Promise.all([getProduct(slug, lang), getSettings(lang)]);
  if (!p) notFound();
  const offers = p.offers.filter((o) => o.active);
  const steps = timelineSteps(p.category, false, lang);
  const price = fromPrice(p, lang);
  // توفير العرض الأطول مقارنة بسعر الشهر الواحد (يُعرض فقط إذا كان فيه عرض شهري للمقارنة)
  const monthly = offers.find((o) => o.months === 1);
  const saving = (o: (typeof offers)[number]) => (monthly && o.months > 1 ? monthly.price_halalas * o.months - o.price_halalas : 0);

  const url = `${siteUrl()}${href(lang, `/programs/${p.slug}`)}`;
  const wa = waLink(s.contact.whatsapp, waIntro(shortName(p.name)));
  return (
    <div className="pub">
      {!p.is_demo && offers.length > 0 && (
        <JsonLd data={{ "@context": "https://schema.org", "@type": "Service", name: p.name, description: p.audience, url, inLanguage: lang, provider: { "@type": "Organization", name: "Nav Coaching", url: siteUrl() },
          areaServed: "SA", offers: offers.map((o) => ({ "@type": "Offer", name: offerLabel(o, lang), price: (o.price_halalas / 100).toFixed(2), priceCurrency: o.currency || "SAR", url })) }} />
      )}
      <section className="page-hero">
        <div className="wrap">
          <nav className="small crumbs" aria-label={u.crumbs}><Link href={href(lang, "/programs")}>{t(lang).nav.programs}</Link> / <span>{categoryLabel(p.category, lang)}</span></nav>
          <div className="row" style={{ marginTop: 14 }}>
            {p.recommended && <span className="tag">{u.mostPopular}</span>}
            {p.is_demo && <span className="tag demo">{u.demo}</span>}
          </div>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 10 }}>{p.name}</h1>
          <p className="lead">{p.audience}</p>
          {price && offers.length > 0 && (
            <div className="hero-buy" data-testid="hero-buy">
              <p className="price"><b className="num">{priceNum(price.value)}</b><span>{CURRENCY[lang]} {price.unit}</span></p>
              <a href="#offers" className="btn">{u.subscribe} <IconArrow size={18} className="arrow" /></a>
            </div>
          )}
        </div>
      </section>

      <section className="section tight">
        <div className="wrap account-layout product-layout">
          <div className="stack" style={{ ["--space" as string]: "22px" }}>
            <div className="card">
              <h2 style={{ fontSize: 22, marginBottom: 16 }}>{u.includes}</h2>
              <ul className="checklist">
                {p.items.map((it) => <li key={it.text} className={it.included ? "" : "no"}>{it.text}</li>)}
              </ul>
              {p.note && <p className="small muted" style={{ marginTop: 14 }}>{p.note}</p>}
            </div>
            <div className="card">
              <dl className="kv">
                {p.delivery && (<><dt>{u.delivery}</dt><dd>{p.delivery}</dd></>)}
                <dt>{u.duration}</dt><dd>{offers.map((o) => offerLabel(o, lang)).join(u.or)}</dd>
                {p.requirements && (<><dt>{u.requirements}</dt><dd>{p.requirements}</dd></>)}
                <dt>{u.reply}</dt><dd>{s.response_time}</dd>
                {p.policy_note && (<><dt>{u.payment}</dt><dd>{p.policy_note} <Link href={href(lang, "/policies#refund")}>{u.details}</Link></dd></>)}
              </dl>
            </div>
            <div className="card flat">
              <h2 style={{ fontSize: 20, marginBottom: 14 }}>{u.after}</h2>
              <ol className="timeline">
                {steps.map((st) => <li key={st.key}>{st.label}</li>)}
              </ol>
              <p className="small muted">{u.notPaid}</p>
            </div>
          </div>

          <aside className="card offers-card" id="offers" aria-label={u.subscribe}>
            <h2 style={{ fontSize: 20 }}>{u.period}</h2>
            <div className="stack" style={{ marginTop: 14 }}>
              {offers.map((o) => (
                <div key={o.sku} className="card flat" style={{ padding: 16 }}>
                  <div className="row" style={{ justifyContent: "space-between" }}>
                    <b>{offerLabel(o, lang)}</b>
                    <span className="price"><b className="num" style={{ fontSize: 26 }}>{priceNum(riyals(o.price_halalas, lang))}</b><span>{CURRENCY[lang]}</span></span>
                  </div>
                  {o.months > 1 && <p className="small muted">≈ {riyals(Math.round(o.price_halalas / o.months), lang)} {u.perMonth}{saving(o) > 0 && <> · <b className="save">{u.save} {riyals(saving(o), lang)}</b></>}</p>}
                  <Link href={`/checkout/${o.sku}`} className="btn btn-block" style={{ marginTop: 12 }}>
                    {u.subscribeIn} {shortName(p.name)} — {offerLabel(o, lang)} <IconArrow size={18} className="arrow" />
                  </Link>
                </div>
              ))}
            </div>
            <p className="small muted" style={{ marginTop: 14 }}>{s.prices_note} {u.student}</p>
          </aside>
        </div>
      </section>
      {/* شريط ثابت أسفل الشاشة على الجوال: السعر وزر الاشتراك في متناول اليد أثناء القراءة */}
      {price && offers.length > 0 && (
        <div className="buy-bar" data-testid="buy-bar">
          <span className="price"><b className="num">{priceNum(price.value)}</b><span>{CURRENCY[lang]} {price.unit}</span></span>
          <span className="row" style={{ gap: 8 }}>
            <a href={wa} target="_blank" rel="noopener" className="btn btn-ghost btn-sm wa-ico" aria-label={t(lang).bar.askWa}><IconWhatsApp size={20} /></a>
            <a href="#offers" className="btn btn-sm">{u.subscribe}</a>
          </span>
        </div>
      )}
    </div>
  );
}
