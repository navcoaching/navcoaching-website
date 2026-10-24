import Link from "next/link";
import ReviewCard from "@/components/ReviewCard";
import { getPublicReviews, getSettings } from "@/lib/data";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/reviews", { title: t(lang).reviews.metaTitle, description: t(lang).reviews.metaDesc });
}

export default async function Reviews({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).reviews;
  const [reviews, s] = await Promise.all([getPublicReviews(), getSettings(lang)]);
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{u.title}</h1>
          <p className="lead">{u.lead}{u.original ? ` ${u.original}` : ""}</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap">
          {reviews.length === 0 && <p className="alert info">{u.empty}</p>}
          <div className="reviews">{reviews.map((r) => <ReviewCard key={r.id} r={r} lang={lang} />)}</div>
          <p className="small muted">{s.testimonials_disclaimer} {u.note} <Link href={href(lang, "/policies#reviews")}>{u.policy}</Link></p>
          <div className="row" style={{ marginTop: 24, gap: "8px 24px" }}>
            <Link href={href(lang, "/programs")} className="btn">{u.pricing}</Link>
            <Link href={href(lang, "/faq")} className="text-link">{u.faq}</Link>
          </div>
        </div>
      </section>
    </div>
  );
}
