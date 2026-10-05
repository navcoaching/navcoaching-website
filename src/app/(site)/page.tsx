import Link from "next/link";
import ProductCard from "@/components/ProductCard";
import GamersBanner from "@/components/GamersBanner";
import Shots from "@/components/Shots";
import { shotSrc } from "@/lib/shot-src";
import YouTubeShort from "@/components/YouTubeShort";
import RichText from "@/components/RichText";
import ReviewCard from "@/components/ReviewCard";
import IntakeCalculator from "./calculator/IntakeCalculator";
import { IconArrow, IconChat, IconFile, IconShield, IconTarget, IconTrend } from "@/components/Icons";
import { getFaqs, getProducts, getPublicReviews, getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";
import JsonLd, { siteUrl } from "@/components/JsonLd";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

const WHY_ICONS = [IconTarget, IconChat, IconTrend];

export default async function Home() {
  const [s, products, reviews, faqs] = await Promise.all([getSettings(), getProducts(), getPublicReviews(6), getFaqs()]);
  const follow = products.filter((p) => p.category === "follow");
  const videoId = youtubeId(s.intro_video?.url);
  const guideId = youtubeId(s.guide_video?.url);
  const guideVertical = /\/shorts\//.test(s.guide_video?.url ?? "");
  const heroMedia = s.hero_image?.media_id;
  // صورة ثابتة توضّح شكل جدول المتدرب (أول لقطة في «نظرة داخل البرنامج»)
  const heroShot = s.program_shots?.[0];
  // لقطة ثانية بجانب خطوات الاشتراك (إن وُجدت)
  const howShot = s.program_shots?.[1] ?? null;

  return (
    <div className="pub">
      <JsonLd data={{ "@context": "https://schema.org", "@graph": [
        { "@type": "Organization", "@id": `${siteUrl()}/#org`, name: "Nav Coaching", url: siteUrl(), logo: `${siteUrl()}/brand/og-logo.png`,
          description: "برامج تدريب وتغذية مخصصة لأهدافك مع الكوتش ساره: خطة منظمة ومتابعة أسبوعية.", ...(s.contact?.instagram ? { sameAs: [s.contact.instagram] } : {}) },
        { "@type": "WebSite", "@id": `${siteUrl()}/#site`, url: siteUrl(), name: "Nav Coaching", inLanguage: "ar", publisher: { "@id": `${siteUrl()}/#org` } },
      ] }} />
      {/* ---------- الهيرو: شبكة نقاط + خطوط الشعار المائلة + معاينة البرنامج ---------- */}
      <section className="hero hero-v2">
        <div className="hero-clip" aria-hidden="true">
          <div className="hero-bars"><i /><i /><i /></div>
          <div className="hero-bars alt"><i /><i /></div>
        </div>
        <div className="wrap hero-center">
          <p className="tagline" lang="en" dir="ltr">{s.hero.tagline || "Where Passion Meets Quality"}</p>
          <p className="eyebrow">{s.hero.eyebrow}</p>
          <h1>
            {s.hero.title}
            {s.hero.title_tail && <> <span className="hl">{s.hero.title_tail}</span></>}
          </h1>
          <p className="lead">{s.hero.lead}</p>
          <div className="row hero-cta">
            <Link href="/programs" className="btn btn-cyan btn-slit">اختر برنامجك <IconArrow size={18} className="arrow" /></Link>
            <Link href="/programs#quiz" className="btn btn-ghost">أي برنامج يناسبني؟</Link>
          </div>
          <ul className="badges" aria-label="مزايا">
            {s.badges.map((b) => <li key={b}>{b}</li>)}
          </ul>
          {heroMedia ? (
            <div className="preview">
              <div className="hero-photo">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={`/api/files/media/${heroMedia}`} alt="" fetchPriority="high" />
              </div>
            </div>
          ) : (
            heroShot && (
              <figure className="preview hero-shot">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={shotSrc(heroShot.src)} alt={heroShot.alt} width={heroShot.w} height={heroShot.h} fetchPriority="high" />
                <figcaption><span className="tag soft">نموذج توضيحي</span> {heroShot.title}</figcaption>
              </figure>
            )
          )}
        </div>
      </section>

      {/* ---------- ليش Nav: شبكة بطاقات (bento) ---------- */}
      <section className="section white">
        <div className="wrap">
          <div className="sec-head reveal">
            <span className="eyebrow">ليش Nav Coaching</span>
            <h2>تدريب مبني <span className="hl">عليك</span>، مو جدول جاهز</h2>
            <p className="lead">كل برنامج يُصمم بعد استبيان مفصل، ويتعدّل حسب قياساتك والتزامك.</p>
          </div>
          <div className="bento">
            {s.why.map((w, i) => {
              const Icon = WHY_ICONS[i % WHY_ICONS.length];
              const wide = i === 0;
              return (
                <div className={`card feature accent reveal ${wide ? "c4" : "c2"}`} key={w.title} style={{ ["--d" as string]: `${i * 90}ms` }}>
                  <span className="ico"><Icon /></span>
                  <h3>{w.title}</h3>
                  <p className="muted">{w.body}</p>
                  {wide && (
                    <ol className="flow" aria-label="دورة المتابعة الأسبوعية">
                      <li><i>📝</i>ترسل مراجعتك<small>يوم المراجعة</small></li>
                      <li><i>👀</i>المدربة تراجع<small>القياسات والالتزام</small></li>
                      <li><i>🎥</i>رد ومتابعة<small>فيديو أو صوت</small></li>
                      <li><i>📈</i>برنامج محدّث<small>الأسبوع الجاي</small></li>
                    </ol>
                  )}
                </div>
              );
            })}
            <div className="card feature reveal c2">
              <span className="ico"><IconFile /></span>
              <h3>طلبك وملفاتك في مكان واحد</h3>
              <p className="muted">من حسابك تشوف حالة طلبك والمطلوب منك، وبعد تأكيد الدفع تظهر ملفات برنامجك ولا يفتحها غيرك.</p>
            </div>
            <div className="card feature darkc reveal c2">
              <span className="ico"><IconShield /></span>
              <h3>بياناتك خاصة</h3>
              <p>إجاباتك الصحية لا يطّلع عليها إلا المدربة، ولا تُرسل في أي تنبيه.</p>
            </div>
          </div>
          <dl className="stats reveal">
            <div><dt>شهادات واعتمادات مهنية</dt><dd className="num">{s.about.certs.length}</dd></div>
            <div><dt>برامج متابعة تختار منها</dt><dd className="num">{follow.length}</dd></div>
            <div><dt>مراجعة وتعديل للبرنامج</dt><dd>كل أسبوع</dd></div>
          </dl>
        </div>
      </section>

      <div className="divider" aria-hidden="true" />

      {/* ---------- البرامج ---------- */}
      <section className="section" id="programs">
        <div className="wrap">
          <div className="sec-head reveal">
            <span className="eyebrow">البرامج</span>
            <h2>اختر مستوى المتابعة اللي يناسبك</h2>
            <p className="lead">كل البرامج مخصصة لك بعد الاستبيان. {s.prices_note}</p>
          </div>
          <div className="grid g4">
            {follow.map((p, i) => <ProductCard key={p.id} p={p} index={i} />)}
          </div>
          <div className="row" style={{ marginTop: 28, justifyContent: "space-between" }}>
            <p className="muted">مو متأكد أي برنامج يناسبك؟ جاوب على 4 أسئلة، وأقترح لك الباقة الأنسب.</p>
            <div className="row">
              <Link href="/programs#quiz" className="btn btn-ghost">ابدأ الاختبار</Link>
              <Link href="/programs" className="btn">كل البرامج والملفات والاستشارات <IconArrow size={18} className="arrow" /></Link>
            </div>
          </div>
        </div>
      </section>

      {/* ---------- باقة القيمرز (تظهر فقط إذا نُشرت باقة gamers) ---------- */}
      <GamersBanner product={products.find((p) => p.slug === "gamers")} whatsapp={s.contact.whatsapp} />

      {/* ---------- مقطع التعريف (يظهر فقط عند إضافة الرابط من لوحة الإدارة) ---------- */}
      {videoId && (
        <section className="section dark" id="intro">
          <div className="wrap short">
            <div className="stack reveal">
              <span className="eyebrow">تعرّف على المدربة</span>
              <h2>{s.intro_video.title}</h2>
              <p className="lead">{s.intro_video.body}</p>
              <p className="muted small">الفيديو لا يعمل تلقائياً. اضغط للتشغيل، أو افتحه في تطبيق يوتيوب.</p>
            </div>
            <div className="reveal" style={{ ["--d" as string]: "120ms" }}>
              <YouTubeShort id={videoId} title={s.intro_video.title} />
            </div>
          </div>
        </section>
      )}

      {/* ---------- نظرة داخل البرنامج + حساب المتدرب ---------- */}
      <section className="section white">
        <div className="wrap">
          <div className="sec-head reveal">
            <span className="eyebrow">نظرة داخل برنامج المتدرب</span>
            <h2>كيف يبدو برنامجك؟</h2>
            <p className="lead">لقطات من ملف المتدرب الفعلي، بدون أي بيانات شخصية. اضغط على الصورة لتكبيرها.</p>
          </div>
          <Shots shots={s.program_shots} />
        </div>
      </section>

      {/* ---------- كيف أشترك ---------- */}
      <section className="section" id="how">
        <div className={`wrap${howShot ? " how-grid" : ""}`}>
          <div>
            <div className="sec-head reveal">
              <span className="eyebrow">كيف أشترك؟</span>
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
              <Link href="/programs" className="btn btn-cyan btn-slit">اختر برنامجك</Link>
              <Link href="/faq" className="btn btn-ghost">الأسئلة الشائعة</Link>
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

      {/* ---------- مقطع شرح استخدام الموقع بالكامل (يظهر عند إضافة الرابط من لوحة الإدارة) ---------- */}
      {guideId && (
        <section className="section white" id="guide-video" data-testid="guide-video">
          <div className={guideVertical ? "wrap short" : "wrap guide-video"}>
            <div className="sec-head reveal" style={guideVertical ? undefined : { textAlign: "center", marginInline: "auto" }}>
              <span className="eyebrow">شرح الموقع</span>
              <h2>{s.guide_video?.title || "شرح استخدام الموقع خطوة بخطوة"}</h2>
              {s.guide_video?.body && <p className="lead">{s.guide_video.body}</p>}
            </div>
            <div className="reveal" style={{ ["--d" as string]: "120ms" }}>
              <YouTubeShort id={guideId} title={s.guide_video?.title || "شرح استخدام الموقع"} wide={!guideVertical} />
            </div>
          </div>
        </section>
      )}

      {/* ---------- عن المدربة ---------- */}
      <section className="section white">
        <div className="wrap grid g2" style={{ alignItems: "center" }}>
          <div className="stack reveal">
            <span className="eyebrow">عن المدربة</span>
            <h2>{s.about.name}</h2>
            <p className="lead">{s.about.home_bio || s.about.bio}</p>
            <Link href="/about" className="btn btn-ghost" style={{ width: "fit-content" }}>اعرف أكثر عني</Link>
          </div>
          <div className="card reveal" style={{ ["--d" as string]: "120ms" }}>
            <h3 style={{ marginBottom: 14 }}>الشهادات والمؤهلات</h3>
            <ul className="checklist">{s.about.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
          </div>
        </div>
      </section>

      {/* ---------- التقييمات ---------- */}
      {reviews.length > 0 && (
        <section className="section">
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

      {/* ---------- الأسئلة الشائعة ---------- */}
      <section className="section white">
        <div className="wrap grid g2" style={{ alignItems: "start" }}>
          <div className="sec-head reveal">
            <span className="eyebrow">الأسئلة الشائعة</span>
            <h2>قبل ما تشترك</h2>
            <p className="lead">ما لقيت جوابك؟ راسلنا على واتساب، والرد خلال {s.response_time}.</p>
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

      {/* ---------- حاسبة السعرات (آخر الصفحة) ---------- */}
      <section className="section" id="calculator" aria-labelledby="home-calc-h">
        <div className="wrap stack" style={{ ["--space" as string]: "20px", maxWidth: 900 }}>
          <div className="sec-head">
            <span className="eyebrow">أداة مجانية</span>
            <h2 id="home-calc-h">حاسبة السعرات اليومية</h2>
            <p className="muted">احسب سعراتك اليومية لهدفك من وزنك وتركيبة جسمك وتمرينك. <Link href="/calculator">حاسبة توازن الطاقة والأسئلة الشائعة</Link></p>
          </div>
          <IntakeCalculator idPrefix="h" />
        </div>
      </section>
    </div>
  );
}
