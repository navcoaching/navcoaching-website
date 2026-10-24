import Link from "next/link";
import ReviewCard from "@/components/ReviewCard";
import { getApprovedMedia, getProducts, getSettings, getPublicReviews } from "@/lib/data";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/about", { title: t(lang).about.metaTitle, description: t(lang).about.metaDesc });
}

/** فقرة تبدأ اختيارياً بجزء عريض بين ** ** */
function Para({ text }: { text: string }) {
  const m = text.match(/^\*\*(.+?)\*\*\s*(.*)$/);
  return m ? <p><b>{m[1]}</b> {m[2]}</p> : <p>{text}</p>;
}

// محتوى وترتيب صفحة «عن المدربة» في الموقع الحالي، وكل النصوص تتعدل من لوحة الإدارة
export default async function About({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).about;
  const [s, photos, products, reviews] = await Promise.all([getSettings(lang), getApprovedMedia("about"), getProducts(lang), getPublicReviews(12)]);
  // ثلاث تقييمات حقيقية قصيرة للختام (من التقييمات المنشورة فقط، بدون تعديل)
  const quotes = reviews.filter((r) => r.body.length <= 230).slice(0, 3);
  const a = s.about;
  const published = new Set(products.map((p) => `/programs/${p.slug}`));
  // رابط منتج لا يظهر إلا إذا كان المنتج منشوراً فعلاً
  const linkOk = (h?: string) => !!h && (!h.startsWith("/programs/") || published.has(h));
  const L = (h: string) => (h.startsWith("/") ? href(lang, h) : h);

  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap about-hero">
          <div>
            <span className="eyebrow">{u.eyebrow}</span>
            <h1 style={{ fontSize: "clamp(32px,6vw,56px)", marginTop: 12 }}>{a.name}</h1>
            <p className="lead">{a.bio}</p>
          </div>
          {/* الصورة المعتمدة من «الصور» إن وُجدت، وإلا صورة المدربة الافتراضية */}
          <figure className="about-photo">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={photos[0] ? `/api/files/media/${photos[0].id}` : "/brand/coach-sara.webp"} alt={photos[0]?.alt || a.name} fetchPriority="high" />
          </figure>
        </div>
      </section>

      {a.story?.length ? (
        <section className="section">
          <div className="wrap prose reveal">
            <span className="eyebrow">{u.story}</span>
            <h2>{a.story_title}</h2>
            {a.story.map((x) => <Para key={x} text={x} />)}
          </div>
        </section>
      ) : null}

      {a.pillars?.length ? (
        <section className="section white">
          <div className="wrap">
            <div className="sec-head reveal"><span className="eyebrow">{u.style}</span><h2>{a.pillars_title}</h2></div>
            <div className="grid g4">
              {a.pillars.map((p, i) => (
                <div key={p.title} className="card feature reveal" style={{ ["--d" as string]: `${i * 80}ms` }}>
                  <h3>{p.title}</h3>
                  <p className="muted">{p.body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>
      ) : null}

      {a.fit?.length || a.notes?.length ? (
        <section className="section">
          <div className="wrap prose reveal">
            <span className="eyebrow">{u.fit}</span>
            <h2>{a.fit_title}</h2>
            {a.fit?.map((x) => <Para key={x} text={x} />)}
            {a.notes?.map((n) => (
              <div key={n.title} className="card note-card">
                <h3>{n.title}</h3>
                <p>{n.body}</p>
                {linkOk(n.href) && <Link href={L(n.href!)} style={{ fontWeight: 700 }}>{n.label || u.more}</Link>}
              </div>
            ))}
          </div>
        </section>
      ) : null}

      <section className="section white">
        <div className="wrap prose reveal">
          <span className="eyebrow">{u.quals}</span>
          <h2>{a.experience_title || u.qualsTitle}</h2>
          <ul className="certs">{a.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
          {a.experience?.length ? <ul>{a.experience.map((e) => <li key={e}>{e}</li>)}</ul> : null}
        </div>
      </section>

      <section className="section">
        <div className="wrap center stack" style={{ justifyItems: "center", display: "grid" }}>
          <h2>{u.said}</h2>
          {quotes.length > 0 && (
            <div className="reviews reviews-home about-quotes" style={{ textAlign: "start", width: "100%" }} tabIndex={0} role="region" aria-label={u.quotesAria}>
              {quotes.map((r) => <ReviewCard key={r.id} r={r} lang={lang} />)}
            </div>
          )}
          <div className="row" style={{ justifyContent: "center", gap: "8px 24px" }}>
            <Link className="btn" href={href(lang, "/programs")}>{u.pricing}</Link>
            <Link className="text-link" href={href(lang, "/reviews")}>{u.reviews}</Link>
          </div>
        </div>
      </section>
    </div>
  );
}
