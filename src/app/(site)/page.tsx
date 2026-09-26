import Link from "next/link";
import ProductCard from "@/components/ProductCard";
import Shots from "@/components/Shots";
import YouTubeShort from "@/components/YouTubeShort";
import RichText from "@/components/RichText";
import ReviewCard from "@/components/ReviewCard";
import { IconArrow, IconChat, IconFile, IconShield, IconTarget, IconTrend } from "@/components/Icons";
import { getFaqs, getProducts, getPublicReviews, getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";

export const revalidate = 300;

const WHY_ICONS = [IconTarget, IconChat, IconTrend];

export default async function Home() {
  const [s, products, reviews, faqs] = await Promise.all([getSettings(), getProducts(), getPublicReviews(6), getFaqs()]);
  const follow = products.filter((p) => p.category === "follow");
  const videoId = youtubeId(s.intro_video?.url);
  const heroMedia = s.hero_image?.media_id;
  // صورة ثابتة توضّح شكل جدول المتدرب (أول لقطة في «نظرة داخل البرنامج»)
  const heroShot = s.program_shots?.[0];

  return (
    <>
      {/* ---------- الهيرو ---------- */}
      <section className="hero">
        <div className={`wrap hero-grid${heroMedia ? "" : " with-shot"}`}>
          <div>
            <p className="eyebrow">{s.hero.eyebrow}</p>
            <h1 style={{ marginTop: 16 }}>
              {s.hero.title}
              {s.hero.title_tail && <span className="hl">{s.hero.title_tail}</span>}
            </h1>
            <p className="lead" style={{ marginTop: 18 }}>{s.hero.lead}</p>
            <div className="row hero-cta">
              <Link href="/programs" className="btn btn-cyan">اختر برنامجك <IconArrow size={18} className="arrow" /></Link>
              <Link href="/programs#quiz" className="btn btn-ghost">أي برنامج يناسبني؟</Link>
            </div>
            <ul className="badges" aria-label="مزايا">
              {s.badges.map((b) => <li key={b}>{b}</li>)}
            </ul>
          </div>
          {heroMedia ? (
            <div className="hero-photo">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={`/api/files/media/${heroMedia}`} alt="" fetchPriority="high" />
            </div>
          ) : (
            heroShot && (
              <figure className="hero-shot">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={heroShot.src} alt={heroShot.alt} width={heroShot.w} height={heroShot.h} fetchPriority="high" />
                <figcaption><span className="tag soft">نموذج توضيحي</span> {heroShot.title}</figcaption>
              </figure>
            )
          )}
        </div>
        <div className="hero-slashes" aria-hidden="true" />
      </section>

      {/* ---------- ليش Nav ---------- */}
      <section className="section white">
        <div className="wrap">
          <div className="sec-head reveal">
            <span className="eyebrow">ليش Nav Coaching</span>
            <h2>تدريب مبني عليك، مو جدول جاهز</h2>
          </div>
          <div className="grid g3">
            {s.why.map((w, i) => {
              const Icon = WHY_ICONS[i % WHY_ICONS.length];
              return (
                <div className="card feature reveal" key={w.title} style={{ ["--d" as string]: `${i * 90}ms` }}>
                  <span className="ico"><Icon /></span>
                  <h3>{w.title}</h3>
                  <p className="muted">{w.body}</p>
                </div>
              );
            })}
          </div>
        </div>
      </section>

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
          <div className="grid g3" style={{ marginTop: 40 }}>
            {[
              { I: IconTrend, t: "تتابع طلبك خطوة بخطوة", b: "من حسابك تشوف حالة طلبك، والمطلوب منك الآن، وتاريخ كل تحديث." },
              { I: IconFile, t: "ملفاتك في مكان واحد", b: "بعد تأكيد الدفع تظهر لك ملفات برنامجك وروابطه، ولا يفتحها غيرك." },
              { I: IconShield, t: "بياناتك خاصة", b: "إجاباتك الصحية لا يطّلع عليها إلا المدربة، ولا تُرسل في أي تنبيه." },
            ].map(({ I, t, b }, i) => (
              <div className="card flat feature reveal" key={t} style={{ ["--d" as string]: `${i * 90}ms` }}>
                <span className="ico"><I /></span>
                <h3>{t}</h3>
                <p className="muted">{b}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ---------- كيف أشترك ---------- */}
      <section className="section dark" id="how">
        <div className="wrap">
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
            <Link href="/programs" className="btn btn-cyan">اختر برنامجك</Link>
            <Link href="/faq" className="btn btn-ghost">الأسئلة الشائعة</Link>
          </div>
        </div>
      </section>

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

      {/* ---------- التجارب ---------- */}
      {reviews.length > 0 && (
        <section className="section">
          <div className="wrap">
            <div className="sec-head reveal">
              <span className="eyebrow">تجارب المتدربين</span>
              <h2>تجارب المتدربين معي</h2>
              <p className="muted small">{s.testimonials_disclaimer}</p>
            </div>
            <div className="reviews">
              {reviews.map((r) => <ReviewCard key={r.id} r={r} />)}
            </div>
            <Link href="/reviews" className="btn btn-ghost" style={{ marginTop: 8 }}>كل التجارب</Link>
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
    </>
  );
}
