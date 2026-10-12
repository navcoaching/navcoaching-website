import type { Metadata } from "next";
import Link from "next/link";
import ReviewCard from "@/components/ReviewCard";
import { getApprovedMedia, getProducts, getSettings, getPublicReviews } from "@/lib/data";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)
export const metadata: Metadata = { title: "عن الكوتش ساره | ناڤ", description: "تعرّفي على الكوتش ساره (ناڤ): خلفيتها في التدريب والتغذية وأسلوب المتابعة الأسبوعية في برامج Nav Coaching." };

/** فقرة تبدأ اختيارياً بجزء عريض بين ** ** */
function Para({ text }: { text: string }) {
  const m = text.match(/^\*\*(.+?)\*\*\s*(.*)$/);
  return m ? <p><b>{m[1]}</b> {m[2]}</p> : <p>{text}</p>;
}

// محتوى وترتيب صفحة «عن المدربة» في الموقع الحالي، وكل النصوص تتعدل من لوحة الإدارة
export default async function About() {
  const [s, photos, products, reviews] = await Promise.all([getSettings(), getApprovedMedia("about"), getProducts(), getPublicReviews(12)]);
  // ثلاث تقييمات حقيقية قصيرة للختام (من التقييمات المنشورة فقط، بدون تعديل)
  const quotes = reviews.filter((r) => r.body.length <= 230).slice(0, 3);
  const a = s.about;
  const published = new Set(products.map((p) => `/programs/${p.slug}`));
  // رابط منتج لا يظهر إلا إذا كان المنتج منشوراً فعلاً
  const linkOk = (href?: string) => !!href && (!href.startsWith("/programs/") || published.has(href));

  return (
    <div className="pub">
      <section className="page-hero">
        <div className={`wrap${photos[0] ? " about-hero" : ""}`}>
          <div>
            <span className="eyebrow">عن المدربة</span>
            <h1 style={{ fontSize: "clamp(32px,6vw,56px)", marginTop: 12 }}>{a.name}</h1>
            <p className="lead">{a.bio}</p>
          </div>
          {photos[0] && (
            <figure className="about-photo">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={`/api/files/media/${photos[0].id}`} alt={photos[0].alt} fetchPriority="high" />
            </figure>
          )}
        </div>
      </section>

      {a.story?.length ? (
        <section className="section">
          <div className="wrap prose reveal">
            <span className="eyebrow">قصتي</span>
            <h2>{a.story_title}</h2>
            {a.story.map((t) => <Para key={t} text={t} />)}
          </div>
        </section>
      ) : null}

      {a.pillars?.length ? (
        <section className="section white">
          <div className="wrap">
            <div className="sec-head reveal"><span className="eyebrow">أسلوبي</span><h2>{a.pillars_title}</h2></div>
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
            <span className="eyebrow">لمن يناسب؟</span>
            <h2>{a.fit_title}</h2>
            {a.fit?.map((t) => <Para key={t} text={t} />)}
            {a.notes?.map((n) => (
              <div key={n.title} className="card note-card">
                <h3>{n.title}</h3>
                <p>{n.body}</p>
                {linkOk(n.href) && <Link href={n.href!} style={{ fontWeight: 700 }}>{n.label || "المزيد ←"}</Link>}
              </div>
            ))}
          </div>
        </section>
      ) : null}

      <section className="section white">
        <div className="wrap prose reveal">
          <span className="eyebrow">المؤهلات والخبرة</span>
          <h2>{a.experience_title || "الشهادات والمؤهلات"}</h2>
          <ul className="certs">{a.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
          {a.experience?.length ? <ul>{a.experience.map((e) => <li key={e}>{e}</li>)}</ul> : null}
        </div>
      </section>

      <section className="section">
        <div className="wrap center stack" style={{ justifyItems: "center", display: "grid" }}>
          <h2>وش قالوا اللي تدربوا معي؟</h2>
          {quotes.length > 0 && (
            <div className="reviews reviews-home about-quotes" style={{ textAlign: "start", width: "100%" }}>
              {quotes.map((r) => <ReviewCard key={r.id} r={r} />)}
            </div>
          )}
          <div className="row" style={{ justifyContent: "center", gap: "8px 24px" }}>
            <Link className="btn" href="/programs">البرامج والأسعار</Link>
            <Link className="text-link" href="/reviews">تقييمات المتدربين ←</Link>
          </div>
        </div>
      </section>
    </div>
  );
}
