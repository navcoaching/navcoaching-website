import Link from "next/link";
import { fromPrice } from "@/components/ProductCard";
import { shortName } from "@/lib/format";
import Marquee from "@/components/home/Marquee";
import RewardCalc from "@/components/home/RewardCalc";
import RichText from "@/components/RichText";
import ReviewCard from "@/components/ReviewCard";
import YouTubeShort from "@/components/YouTubeShort";
import { youtubeId } from "@/lib/youtube";
import { IconArrow, IconLock } from "@/components/Icons";
import { getFaqs, getProducts, getPublicReviews, getSettings } from "@/lib/data";
import JsonLd, { siteUrl } from "@/components/JsonLd";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

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

  return (
    <div className="pub v3">
      <JsonLd data={{ "@context": "https://schema.org", "@graph": [
        { "@type": "Organization", "@id": `${siteUrl()}/#org`, name: "Nav Coaching", url: siteUrl(), logo: `${siteUrl()}/brand/og-logo.png`,
          description: "برامج تدريب وتغذية مخصصة حسب الهدف مع الكوتش ساره: خطة منظمة ومتابعة أسبوعية.", sameAs: [s.contact?.instagram, s.contact?.tiktok].filter(Boolean) },
        { "@type": "WebSite", "@id": `${siteUrl()}/#site`, url: siteUrl(), name: "Nav Coaching", inLanguage: "ar", publisher: { "@id": `${siteUrl()}/#org` } },
      ] }} />
      {/* ---------- 1. الواجهة: غامقة بخطوط الشعار المائلة، النص يمين ولقطات التطبيق يسار ---------- */}
      <section className="v3-hero">
        <div className="wrap v3-hero-in">
          <div className="v3-hero-copy">
            <h1>
              <span className="l"><span>{s.hero.title}</span></span>
              {s.hero.title_tail && <span className="l"><span><span className="hl">{s.hero.title_tail}</span></span></span>}
            </h1>
            <p className="lead">{s.hero.lead}</p>
            <div className="v3-acts">
              <a href="#programs" className="btn v3-btn-cyan">البرامج والأسعار <IconArrow size={18} className="arrow" /></a>
              <Link href="/programs#quiz" className="text-link">أي برنامج يناسبني؟</Link>
            </div>
            {s.badges.length > 0 && (
              <ul className="v3-facts" data-testid="trust-line">{s.badges.map((b) => <li key={b}>{b}</li>)}</ul>
            )}
          </div>
          <figure className="v3-frame">
            <div className="v3-slab" aria-hidden="true" />
            {heroMedia ? (
              <div className="v3-shot v3-shot-front upload">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img className="hero-upload" src={`/api/files/media/${heroMedia}`} alt="" fetchPriority="high" />
              </div>
            ) : (
              <>
                <div className="v3-shot v3-shot-back" aria-hidden="true">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src="/shots/training-log.webp" alt="" width={1188} height={993} loading="lazy" />
                </div>
                <div className="v3-shot v3-shot-front">
                  {/* لقطة شاشة حقيقية من صفحة «برنامجي» ببيانات مثال (نسخة لكل وضع) */}
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img className="l-light" src="/shots/hero-program.webp" alt="لقطة من صفحة «برنامجي» ببيانات مثال: الالتزام، أيام تمرين الأسبوع، وتغذية اليوم" width={1288} height={1118} fetchPriority="high" />
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img className="l-dark" src="/shots/hero-program-dark.webp" alt="لقطة من صفحة «برنامجي» ببيانات مثال: الالتزام، أيام تمرين الأسبوع، وتغذية اليوم" width={1288} height={1118} />
                </div>
              </>
            )}
            <figcaption className="v3-chip"><span>نموذج توضيحي</span><b>لوحة المتدرب</b></figcaption>
          </figure>
        </div>
      </section>

      <Marquee items={[...s.why.map((w) => w.title), `رد خلال ${s.response_time.split(" (")[0]}`]} />

      {/* ---------- 2. عن المدربة ---------- */}
      <section className="v3-about" id="about">
        <div className="wrap v3-about-in">
          <div className="v3-portrait reveal" aria-hidden="true">
            <i className="s-a" /><i className="s-b" />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <div className="ph"><img src="/brand/coach-sara-portrait.webp" alt="" width={640} height={800} loading="lazy" /></div>
          </div>
          <div className="reveal" style={{ ["--d" as string]: "90ms" }}>
            <h2>{s.about.name}</h2>
            <p className="v3-bio">{s.about.home_bio || s.about.bio}</p>
            <ul className="v3-certs" aria-label="الشهادات والمؤهلات">{s.about.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
            <Link href="/about" className="text-link">القصة كاملة ←</Link>
          </div>
        </div>
        {videoId && (
          <div className="wrap short v3-intro" id="intro">
            <div className="stack reveal">
              <h3>{s.intro_video.title}</h3>
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
      <section className="v3-plans" id="programs">
        <div className="wrap">
          <h2 className="v3-h2 reveal">اختيار مستوى المتابعة</h2>
          <p className="v3-sub reveal">كل البرامج مخصصة حسب الهدف بعد الاستبيان. {s.prices_note}</p>
          <div className="v3-pgrid">
            {main.map((p, i) => {
              const price = fromPrice(p);
              const items = p.items.filter((x) => x.included).slice(0, 3);
              return (
                <Link key={p.id} href={`/programs/${p.slug}`} className={`v3-plan reveal${p.recommended ? " feat" : ""}`} style={{ ["--d" as string]: `${i * 80}ms` }}>
                  {p.recommended && <span className="v3-badge">الأكثر طلباً</span>}
                  {p.is_demo && <span className="tag demo">تجريبي</span>}
                  <h3>{shortName(p.name)}</h3>
                  <p className="for">{p.audience}</p>
                  {price && (
                    <>
                      <p className="price"><b className="num">{price.value.replace(" ر.س", "")}</b> <span>ر.س {price.unit}</span></p>
                      {price.extra && <p className="extra">{price.extra}</p>}
                    </>
                  )}
                  {items.length > 0 && <ul>{items.map((x) => <li key={x.text}>{x.text}</li>)}</ul>}
                  <span className="more">التفاصيل والاشتراك <IconArrow size={18} /></span>
                </Link>
              );
            })}
          </div>
          {special.length > 0 && (
            <div className="v3-special reveal">
              <h3 id="special">مسارات خاصة</h3>
              {special.map((p) => {
                const price = fromPrice(p);
                return (
                  <Link key={p.id} href={`/programs/${p.slug}`} className="v3-sp">
                    <b>{shortName(p.name)}</b>
                    <span>{price ? `${price.value} ${price.unit} · ` : ""}{p.audience}</span>
                    <i aria-hidden="true">←</i>
                  </Link>
                );
              })}
            </div>
          )}
          <p className="programs-quiz">4 أسئلة تحدد البرنامج المناسب. <Link href="/programs#quiz" className="text-link">بدء الاختبار</Link></p>
          <p className="small muted programs-note">خصم 10% للطلاب · مجاني لأهل غزة · الدفع بتحويل بنكي</p>
          <Link href="/programs" className="text-link small">كل البرامج والملفات والاستشارات ←</Link>
        </div>
      </section>

      {/* ---------- 4. ليش Nav Coaching: الأسباب مع لقطات حقيقية من حساب المتدرب ---------- */}
      <section className="v3-why" id="why">
        <div className="wrap v3-why-in">
          <div>
            <h2 className="v3-h2 reveal">تدريب مبني <span className="hl">عليك</span>، أسبوع بعد أسبوع</h2>
            <p className="v3-sub reveal">كل برنامج يُصمم بعد استبيان مفصل، ويتعدّل حسب القياسات والالتزام.</p>
            <ul className="v3-reasons reveal">
              {s.why.map((w) => <li key={w.title}><b>{w.title}</b>{w.body}</li>)}
            </ul>
            <p className="why-note"><IconLock size={18} /> الطلب وملفات البرنامج في مكان واحد داخل الحساب، والإجابات الصحية لا يطّلع عليها إلا المدربة ولا تُرسل في أي تنبيه.</p>
          </div>
          <div className="v3-stack" aria-label="لقطات من حساب المتدرب ببيانات مثال">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <figure className="s1"><img src="/shots/my-program.webp" alt="صفحة «برنامجي»" width={1183} height={1130} loading="lazy" /></figure>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <figure className="s2"><img src="/shots/training-log.webp" alt="تسجيل التمرين" width={1188} height={993} loading="lazy" /></figure>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <figure className="s3"><img src="/shots/nutrition-day.webp" alt="سجل التغذية" width={1477} height={1312} loading="lazy" /></figure>
          </div>
        </div>
      </section>

      {/* ---------- 5. ثلاث خطوات لأول تمرين ---------- */}
      <section className="v3-how" id="how">
        <i className="v3-bg-stroke" aria-hidden="true" />
        <div className="wrap">
          <h2 className="v3-h2 reveal">ثلاث خطوات لأول تمرين</h2>
          <ol className="v3-steps">
            {s.how_steps.map((st, i) => (
              <li key={st.title} className="reveal" style={{ ["--d" as string]: `${i * 90}ms` }}>
                <h3>{st.title}</h3>
                <p>{st.body}</p>
              </li>
            ))}
          </ol>
          <a href="#programs" className="btn v3-btn-cyan">البرامج والأسعار</a>
        </div>
      </section>

      {/* ---------- 6. مكافأة الالتزام ---------- */}
      <section className="v3-reward" id="reward">
        <div className="wrap v3-reward-in">
          <div className="reveal">
            <h2 className="v3-h2">التزم 12 أسبوع، <em>والأشهر الثلاثة علينا</em></h2>
            <p className="v3-sub">في باقات الثلاثة أشهر: التزام 90% خلال 12 أسبوع يعطيك 3 أشهر مجاناً. تجربة الأرقام هنا.</p>
          </div>
          <RewardCalc />
        </div>
      </section>

      {/* ---------- 7. التقييمات ---------- */}
      {reviews.length > 0 && (
        <section className="v3-reviews" id="reviews">
          <div className="wrap">
            <h2 className="v3-h2 reveal">تقييمات المتدربين</h2>
            <p className="v3-sub reveal">{s.testimonials_disclaimer}</p>
            <div className="reviews reviews-home">
              {reviews.map((r) => <ReviewCard key={r.id} r={r} />)}
            </div>
            <Link href="/reviews" className="btn v3-btn-navy">كل التقييمات</Link>
          </div>
        </section>
      )}

      {/* ---------- 8. الأسئلة الشائعة ---------- */}
      <section className="v3-faq" id="faq">
        <div className="wrap v3-faq-in">
          <div className="reveal">
            <h2 className="v3-h2">قبل الاشتراك</h2>
            <p className="v3-sub">لم يظهر الجواب؟ التواصل عبر واتساب، والرد خلال {s.response_time}.</p>
            <div className="row"><Link href="/faq" className="text-link">كل الأسئلة</Link><Link href="/policies" className="text-link">السياسات</Link></div>
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

      {/* ---------- 9. الختام ---------- */}
      <section className="v3-close">
        <div className="wrap">
          <h2 className="reveal">برنامجك يبدأ من استبيانك</h2>
          <p className="reveal">{s.how_steps[0]?.body ?? "اختيار الباقة ثم استبيان قصير عن الهدف والمستوى والأيام المتاحة."}</p>
          <a href="#programs" className="btn v3-btn-ink reveal">البرامج والأسعار <IconArrow size={18} className="arrow" /></a>
        </div>
      </section>
    </div>
  );
}
