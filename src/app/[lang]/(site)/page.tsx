import Link from "next/link";
import { fromPrice } from "@/components/ProductCard";
import { CURRENCY, priceNum, shortName } from "@/lib/format";
import Marquee from "@/components/home/Marquee";
import RewardCalc from "@/components/home/RewardCalc";
import RichText from "@/components/RichText";
import ReviewCard from "@/components/ReviewCard";
import YouTubeShort from "@/components/YouTubeShort";
import { youtubeId } from "@/lib/youtube";
import { IconArrow, IconLock } from "@/components/Icons";
import { getFaqs, getProducts, getPublicReviews, getSettings } from "@/lib/data";
import JsonLd, { siteUrl } from "@/components/JsonLd";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };

export async function generateMetadata({ params }: P) {
  return pageMeta(await langOf(params), "/");
}

export default async function Home({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).home;
  const L = (p: string) => href(lang, p);
  const [s, products, reviews, faqs] = await Promise.all([getSettings(lang), getProducts(lang), getPublicReviews(6), getFaqs(lang)]);
  // الصف الأول: باقات المتابعة الثلاث الرئيسية، وتحتها «مسارات خاصة» (القيمرز والتغذية وأي باقة متابعة أخرى)
  const MAIN = ["intensive", "advanced", "basic"];
  const main = MAIN.map((slug) => products.find((p) => p.slug === slug)).filter((p) => p !== undefined);
  const special = products.filter((p) => !MAIN.includes(p.slug) && (p.category === "follow" || p.slug === "gamers"));
  // مقطع «تعرّف على المدربة» (يظهر داخل قسم المدربة فقط إذا أُضيف رابطه من لوحة الإدارة)
  const videoId = youtubeId(s.intro_video?.url);
  // صورة الواجهة من لوحة الإدارة (إن اختارتها المدربة) تحل محل لقطة «برنامجي»
  const heroMedia = s.hero_image?.media_id;
  const orgDesc = lang === "en" ? "Personalised training and nutrition programs with Coach Sara: a structured plan and weekly follow-up." : "برامج تدريب وتغذية مخصصة حسب الهدف مع الكوتش ساره: خطة منظمة ومتابعة أسبوعية.";

  return (
    <div className="pub v3">
      <JsonLd data={{ "@context": "https://schema.org", "@graph": [
        { "@type": "Organization", "@id": `${siteUrl()}/#org`, name: "Nav Coaching", url: siteUrl(), logo: `${siteUrl()}/brand/og-logo.png`,
          description: orgDesc, sameAs: [s.contact?.instagram, s.contact?.tiktok].filter(Boolean) },
        { "@type": "WebSite", "@id": `${siteUrl()}/#site`, url: siteUrl(), name: "Nav Coaching", inLanguage: lang, publisher: { "@id": `${siteUrl()}/#org` } },
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
              <a href="#programs" className="btn v3-btn-cyan">{u.pricingArrow} <IconArrow size={18} className="arrow" /></a>
              <Link href={L("/programs#quiz")} className="text-link">{u.whichFits}</Link>
            </div>
            {s.badges.length > 0 && (
              <ul className="v3-facts" data-testid="trust-line">{s.badges.map((b) => <li key={b}>{b}</li>)}</ul>
            )}
          </div>
          <figure className="v3-frame">
            <i className="v3-glow" aria-hidden="true" />
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
                  <img className="l-light" src="/shots/hero-program.webp" alt={u.heroAlt} width={1288} height={1118} fetchPriority="high" />
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img className="l-dark" src="/shots/hero-program-dark.webp" alt={u.heroAlt} width={1288} height={1118} />
                </div>
              </>
            )}
            <figcaption className="v3-chip"><span>{t(lang).common.sample}</span><b>{u.chip}</b></figcaption>
          </figure>
        </div>
      </section>

      <Marquee items={[...s.why.map((w) => w.title), `${u.replyWithin} ${s.response_time.split(" (")[0]}`]} />

      {/* ---------- 2. عن المدربة ---------- */}
      <section className="v3-about" id="about">
        <div className="wrap v3-about-in">
          <div className="v3-portrait reveal" aria-hidden="true">
            <i className="s-a" /><i className="s-b" />
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <div className="ph"><img src="/brand/coach-sara-portrait.webp" alt="" width={640} height={800} loading="lazy" /></div>
          </div>
          <div className="reveal" style={{ ["--d" as string]: "90ms" }}>
            <h2 data-story>{s.about.name}</h2>
            <p className="v3-bio" data-fill>{s.about.home_bio || s.about.bio}</p>
            <ul className="v3-certs" aria-label={u.certsAria}>{s.about.certs.map((c) => <li key={c}><bdi>{c}</bdi></li>)}</ul>
            <Link href={L("/about")} className="text-link">{u.fullStory}</Link>
          </div>
        </div>
        {videoId && (
          <div className="wrap short v3-intro" id="intro">
            <div className="stack reveal">
              <h3>{s.intro_video.title}</h3>
              <p className="lead">{s.intro_video.body}</p>
              <p className="muted small">{u.videoNote}</p>
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
          <p className="v3-eyebrow reveal">{u.programs}</p>
          <h2 className="v3-h2 reveal" data-story>{u.chooseLevel}</h2>
          <p className="v3-sub reveal" data-fill>{u.allCustom} {s.prices_note}</p>
          <div className="v3-pgrid">
            {main.map((p, i) => {
              const price = fromPrice(p, lang);
              const items = p.items.filter((x) => x.included).slice(0, 3);
              return (
                <Link key={p.id} href={L(`/programs/${p.slug}`)} className={`v3-plan reveal${p.recommended ? " feat" : ""}`} style={{ ["--d" as string]: `${i * 80}ms` }}>
                  {p.recommended && <span className="v3-badge">{u.mostPopular}</span>}
                  {p.is_demo && <span className="tag demo">{u.demo}</span>}
                  <h3>{shortName(p.name)}</h3>
                  <p className="for">{p.audience}</p>
                  {price && (
                    <>
                      <p className="price"><b className="num">{priceNum(price.value)}</b> <span>{CURRENCY[lang]} {price.unit}</span></p>
                      {price.extra && <p className="extra">{price.extra}</p>}
                    </>
                  )}
                  {items.length > 0 && <ul>{items.map((x) => <li key={x.text}>{x.text}</li>)}</ul>}
                  <span className="more">{u.detailsSubscribe} <IconArrow size={18} /></span>
                </Link>
              );
            })}
          </div>
          {special.length > 0 && (
            <div className="v3-special reveal">
              <h3 id="special">{u.special}</h3>
              {special.map((p) => {
                const price = fromPrice(p, lang);
                return (
                  <Link key={p.id} href={L(`/programs/${p.slug}`)} className="v3-sp">
                    <b>{shortName(p.name)}</b>
                    <span>{price ? `${price.value} ${price.unit} · ` : ""}{p.audience}</span>
                    <i aria-hidden="true">{lang === "en" ? "→" : "←"}</i>
                  </Link>
                );
              })}
            </div>
          )}
          <p className="programs-quiz">{u.quiz} <Link href={L("/programs#quiz")} className="text-link">{u.startQuiz}</Link></p>
          <p className="small muted programs-note">{u.note}</p>
          <Link href={L("/programs")} className="text-link small">{u.allPrograms}</Link>
        </div>
      </section>

      {/* ---------- 4. ليش Nav Coaching: الأسباب مع لقطات حقيقية من حساب المتدرب ---------- */}
      <section className="v3-why" id="why">
        <div className="wrap v3-why-in">
          <div>
            <p className="v3-eyebrow reveal">{u.whyEyebrow}</p>
            <h2 className="v3-h2 reveal" data-story>{u.whyTitle1}<span className="hl">{u.whyHl}</span>{u.whyTitle2}</h2>
            <p className="v3-sub reveal" data-fill>{u.whySub}</p>
            <ul className="v3-reasons reveal">
              {s.why.map((w) => <li key={w.title}><b>{w.title}</b>{w.body}</li>)}
            </ul>
            <p className="why-note"><IconLock size={18} /> {u.whyNote}</p>
          </div>
          <div className="v3-stack" aria-label={u.shotsAria}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <figure className="s1"><img src="/shots/my-program.webp" alt={u.shot1} width={1183} height={1130} loading="lazy" /></figure>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <figure className="s2"><img src="/shots/training-log.webp" alt={u.shot2} width={1188} height={993} loading="lazy" /></figure>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <figure className="s3"><img src="/shots/nutrition-day.webp" alt={u.shot3} width={1477} height={1312} loading="lazy" /></figure>
          </div>
        </div>
      </section>

      {/* ---------- 5. ثلاث خطوات لأول تمرين ---------- */}
      <section className="v3-how" id="how">
        <i className="v3-bg-stroke" aria-hidden="true" />
        <div className="wrap">
          <p className="v3-eyebrow reveal">{u.howEyebrow}</p>
          <h2 className="v3-h2 reveal" data-story>{u.howTitle}</h2>
          <ol className="v3-steps">
            {s.how_steps.map((st, i) => (
              <li key={st.title} className="reveal" style={{ ["--d" as string]: `${i * 90}ms` }}>
                <h3>{st.title}</h3>
                <p>{st.body}</p>
              </li>
            ))}
          </ol>
          <a href="#programs" className="btn v3-btn-cyan">{u.pricingArrow}</a>
        </div>
      </section>

      {/* ---------- 6. مكافأة الالتزام ---------- */}
      <section className="v3-reward" id="reward">
        <div className="wrap v3-reward-in">
          <div className="reveal">
            <p className="v3-eyebrow">{u.rewardEyebrow}</p>
            <h2 className="v3-h2" data-story>{u.rewardTitle1}<em>{u.rewardTitleEm}</em></h2>
            <p className="v3-sub" data-fill>{u.rewardSub}</p>
          </div>
          <RewardCalc />
        </div>
      </section>

      {/* ---------- 7. التقييمات ---------- */}
      {reviews.length > 0 && (
        <section className="v3-reviews" id="reviews">
          <div className="wrap">
            <p className="v3-eyebrow reveal">{u.reviewsEyebrow}</p>
            <h2 className="v3-h2 reveal" data-story>{u.reviewsTitle}</h2>
            <p className="v3-sub reveal" data-fill>{s.testimonials_disclaimer}</p>
            <div className="reviews reviews-home" tabIndex={0} role="region" aria-label={u.reviewsTitle}>
              {reviews.map((r) => <ReviewCard key={r.id} r={r} lang={lang} />)}
            </div>
            <Link href={L("/reviews")} className="btn v3-btn-navy">{u.allReviews}</Link>
          </div>
        </section>
      )}

      {/* ---------- 8. الأسئلة الشائعة ---------- */}
      <section className="v3-faq" id="faq">
        <div className="wrap v3-faq-in">
          <div className="reveal">
            <p className="v3-eyebrow">{u.faqEyebrow}</p>
            <h2 className="v3-h2" data-story>{u.faqTitle}</h2>
            <p className="v3-sub" data-fill>{u.faqSub1} {s.response_time}.</p>
            <div className="row"><Link href={L("/faq")} className="text-link">{u.allFaq}</Link><Link href={L("/policies")} className="text-link">{u.policies}</Link></div>
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
          <h2 className="reveal">{u.closeTitle}</h2>
          <p className="reveal">{s.how_steps[0]?.body ?? u.closeFallback}</p>
          <a href="#programs" className="btn v3-btn-ink reveal">{u.pricingArrow} <IconArrow size={18} className="arrow" /></a>
        </div>
      </section>
    </div>
  );
}
