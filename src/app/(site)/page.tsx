import Link from "next/link";
import ProductCard from "@/components/ProductCard";
import { shotSrc } from "@/lib/shot-src";
import RichText from "@/components/RichText";
import ReviewCard from "@/components/ReviewCard";
import YouTubeShort from "@/components/YouTubeShort";
import { youtubeId } from "@/lib/youtube";
import { IconArrow, IconChat, IconClipboard, IconEye, IconLock, IconTarget, IconTrend, IconVideo } from "@/components/Icons";
import { getFaqs, getProducts, getPublicReviews, getSettings } from "@/lib/data";
import JsonLd, { siteUrl } from "@/components/JsonLd";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

const WHY_ICONS = [IconTarget, IconChat, IconTrend];

export default async function Home() {
  const [s, products, reviews, faqs] = await Promise.all([getSettings(), getProducts(), getPublicReviews(6), getFaqs()]);
  // الصف الأول: باقات المتابعة الثلاث الرئيسية، وتحتها «مسارات خاصة» (القيمرز والتغذية وأي باقة متابعة أخرى)
  const MAIN = ["intensive", "advanced", "basic"];
  const main = MAIN.map((slug) => products.find((p) => p.slug === slug)).filter((p) => p !== undefined);
  const special = products.filter((p) => !MAIN.includes(p.slug) && (p.category === "follow" || p.slug === "gamers"));
  // مقطع «تعرّف على المدربة» (يظهر داخل قسم المدربة فقط إذا أُضيف رابطه من لوحة الإدارة)
  const videoId = youtubeId(s.intro_video?.url);
  // صورة الواجهة من لوحة الإدارة (إن اختارتها المدربة) تحل محل لقطة «برنامجي»
  const heroMedia = s.hero_image?.media_id;
  // لقطة ثانية بجانب خطوات الاشتراك (إن وُجدت)
  const howShot = s.program_shots?.[1] ?? null;

  return (
    <div className="pub">
      <JsonLd data={{ "@context": "https://schema.org", "@graph": [
        { "@type": "Organization", "@id": `${siteUrl()}/#org`, name: "Nav Coaching", url: siteUrl(), logo: `${siteUrl()}/brand/og-logo.png`,
          description: "برامج تدريب وتغذية مخصصة حسب الهدف مع الكوتش ساره: خطة منظمة ومتابعة أسبوعية.", ...(s.contact?.instagram ? { sameAs: [s.contact.instagram] } : {}) },
        { "@type": "WebSite", "@id": `${siteUrl()}/#site`, url: siteUrl(), name: "Nav Coaching", inLanguage: "ar", publisher: { "@id": `${siteUrl()}/#org` } },
      ] }} />
      {/* ---------- 1. الهيرو: النص يمين والمعاينة يسار (عمود واحد على الجوال)، وخطوط الشعار المائلة في الخلفية ---------- */}
      <section className="hero hero-v2 hero-split">
        <div className="hero-clip" aria-hidden="true">
          <div className="hero-bars"><i /><i /><i /></div>
          <div className="hero-bars alt"><i /><i /></div>
        </div>
        <div className="wrap hero-cols">
          <div className="hero-copy">
            <h1>
              {s.hero.title}
              {s.hero.title_tail && <span className="hl">{s.hero.title_tail}</span>}
            </h1>
            <p className="lead">{s.hero.lead}</p>
            <div className="hero-cta">
              <a href="#programs" className="btn">البرامج والأسعار <IconArrow size={18} className="arrow" /></a>
              <Link href="/programs#quiz" className="text-link">أي برنامج يناسبني؟</Link>
            </div>
            {s.badges.length > 0 && (
              <p className="trust-line" data-testid="trust-line">
                {s.badges.map((b, i) => <span key={b}>{i > 0 && <i aria-hidden="true">·</i>}{b}</span>)}
              </p>
            )}
          </div>
          <figure className="hero-frame">
            {heroMedia ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img className="hero-upload" src={`/api/files/media/${heroMedia}`} alt="" fetchPriority="high" />
            ) : (
              <>
                {/* لقطة شاشة حقيقية من صفحة «برنامجي» ببيانات مثال (نسخة لكل وضع) */}
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img className="l-light" src="/shots/hero-program.webp" alt="لقطة من صفحة «برنامجي» ببيانات مثال: الالتزام، أيام تمرين الأسبوع، وتغذية اليوم" width={1288} height={1118} fetchPriority="high" />
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img className="l-dark" src="/shots/hero-program-dark.webp" alt="لقطة من صفحة «برنامجي» ببيانات مثال: الالتزام، أيام تمرين الأسبوع، وتغذية اليوم" width={1288} height={1118} />
              </>
            )}
            <figcaption><span className="tag soft">نموذج توضيحي</span> لوحة المتدرب</figcaption>
          </figure>
        </div>
      </section>

      {/* ---------- 2. عن المدربة (مختصر + المؤهلات) ---------- */}
      <section className="section white" id="about">
        <div className="wrap grid g2" style={{ alignItems: "center" }}>
          <div className="stack reveal">
            <div className="coach-head">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src="/brand/coach-sara-portrait.webp" alt="" width={640} height={800} loading="lazy" />
              <div>
                <span className="eyebrow">عن المدربة</span>
                <h2>{s.about.name}</h2>
              </div>
            </div>
            <p className="lead">{s.about.home_bio || s.about.bio}</p>
            <Link href="/about" className="text-link">القصة كاملة ←</Link>
          </div>
          <div className="card reveal" style={{ ["--d" as string]: "120ms" }}>
            <h3 style={{ marginBottom: 14 }}>الشهادات والمؤهلات</h3>
            <ul className="checklist">{s.about.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
          </div>
        </div>
        {videoId && (
          <div className="wrap short" id="intro" style={{ marginTop: 40 }}>
            <div className="stack reveal">
              <h3 style={{ fontSize: 22 }}>{s.intro_video.title}</h3>
              <p className="lead">{s.intro_video.body}</p>
              <p className="muted small">الفيديو لا يعمل تلقائياً: تشغيل المقطع من الصورة، أو فتحه في تطبيق يوتيوب.</p>
            </div>
            <div className="reveal" style={{ ["--d" as string]: "120ms" }}>
              <YouTubeShort id={videoId} title={s.intro_video.title} />
            </div>
          </div>
        )}
      </section>

      {/* ---------- 3. البرامج ---------- */}
      <section className="section deco" id="programs">
        <div className="wrap">
          <div className="sec-head reveal">
            <span className="eyebrow">البرامج</span>
            <h2>اختيار مستوى المتابعة</h2>
            <p className="lead">كل البرامج مخصصة حسب الهدف بعد الاستبيان. {s.prices_note}</p>
          </div>
          <div className="grid g3">
            {main.map((p, i) => <ProductCard key={p.id} p={p} index={i} />)}
          </div>
          {special.length > 0 && (
            <>
              <h3 className="sub-head" id="special">مسارات خاصة</h3>
              <div className="grid g3 special-row">
                {special.map((p, i) => <ProductCard key={p.id} p={p} index={i} />)}
              </div>
            </>
          )}
          <p className="programs-quiz">4 أسئلة تحدد البرنامج المناسب. <Link href="/programs#quiz" className="text-link">بدء الاختبار</Link></p>
          <p className="small muted programs-note">خصم 10% للطلاب · مجاني لأهل غزة · الدفع بتحويل بنكي</p>
          <Link href="/programs" className="text-link small">كل البرامج والملفات والاستشارات ←</Link>
        </div>
      </section>

      {/* ---------- 4. ليش Nav Coaching (دورة المتابعة الأسبوعية) ---------- */}
      <section className="section white">
        <div className="wrap">
          <div className="sec-head reveal">
            <span className="eyebrow">ليش Nav Coaching</span>
            <h2>تدريب مبني <span className="hl">عليك</span>، أسبوع بعد أسبوع</h2>
            <p className="lead">كل برنامج يُصمم بعد استبيان مفصل، ويتعدّل حسب القياسات والالتزام.</p>
          </div>
          <div className="bento">
            {s.why.map((w, i) => {
              const Icon = WHY_ICONS[i % WHY_ICONS.length];
              const wide = i === 0;
              return (
                <div className={`card feature accent reveal ${wide ? "c6" : "c3"}`} key={w.title} style={{ ["--d" as string]: `${i * 90}ms` }}>
                  <span className="ico"><Icon /></span>
                  <h3>{w.title}</h3>
                  <p className="muted">{w.body}</p>
                  {wide && (
                    <ol className="flow" aria-label="دورة المتابعة الأسبوعية">
                      <li><i><IconClipboard /></i>إرسال المراجعة<small>يوم المراجعة</small></li>
                      <li><i><IconEye /></i>المدربة تراجع<small>القياسات والالتزام</small></li>
                      <li><i><IconVideo /></i>رد ومتابعة<small>فيديو أو صوت</small></li>
                      <li><i><IconTrend /></i>برنامج محدّث<small>الأسبوع الجاي</small></li>
                    </ol>
                  )}
                </div>
              );
            })}
          </div>
          <p className="why-note reveal"><IconLock size={18} /> الطلب وملفات البرنامج في مكان واحد داخل الحساب، والإجابات الصحية لا يطّلع عليها إلا المدربة ولا تُرسل في أي تنبيه.</p>
        </div>
      </section>

      {/* ---------- 5. التقييمات ---------- */}
      {reviews.length > 0 && (
        <section className="section deco alt">
          <div className="wrap">
            <div className="sec-head reveal">
              <span className="eyebrow">التقييمات</span>
              <h2>تقييمات المتدربين</h2>
              <p className="muted small">{s.testimonials_disclaimer}</p>
            </div>
            <div className="reviews reviews-home">
              {reviews.map((r) => <ReviewCard key={r.id} r={r} />)}
            </div>
            <Link href="/reviews" className="btn btn-ghost" style={{ marginTop: 8 }}>كل التقييمات</Link>
          </div>
        </section>
      )}

      {/* ---------- 6. ثلاث خطوات لأول تمرين ---------- */}
      <section className="section white" id="how">
        <div className={`wrap${howShot ? " how-grid" : ""}`}>
          <div>
            <div className="sec-head reveal">
              <span className="eyebrow">طريقة الاشتراك</span>
              <h2>ثلاث خطوات لأول تمرين</h2>
            </div>
            <ol className="steps">
              {s.how_steps.map((st, i) => (
                <li key={st.title} className="reveal" style={{ ["--d" as string]: `${i * 100}ms` }}>
                  <h3>{st.title}</h3>
                  <p>{st.body}</p>
                </li>
              ))}
            </ol>
            <div className="row" style={{ marginTop: 28 }}>
              <a href="#programs" className="btn">البرامج والأسعار</a>
            </div>
          </div>
          {howShot && (
            <figure className="how-shot reveal" style={{ ["--d" as string]: "120ms" }}>
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={shotSrc(howShot.src)} alt={howShot.alt} width={howShot.w} height={howShot.h} loading="lazy" />
            </figure>
          )}
        </div>
      </section>

      {/* ---------- 7. الأسئلة الشائعة ---------- */}
      <section className="section deco">
        <div className="wrap grid g2" style={{ alignItems: "start" }}>
          <div className="sec-head reveal">
            <span className="eyebrow">الأسئلة الشائعة</span>
            <h2>قبل الاشتراك</h2>
            <p className="lead">لم يظهر الجواب؟ التواصل عبر واتساب، والرد خلال {s.response_time}.</p>
            <div className="row">
              <Link href="/faq" className="btn btn-ghost">كل الأسئلة</Link>
              <Link href="/policies" className="btn btn-ghost">السياسات</Link>
            </div>
          </div>
          <div className="faq reveal">
            {faqs.slice(0, 5).map((f) => (
              <details key={f.id}>
                <summary>{f.question}</summary>
                <div className="ans"><RichText text={f.answer} /></div>
              </details>
            ))}
          </div>
        </div>
      </section>
    </div>
  );
}
