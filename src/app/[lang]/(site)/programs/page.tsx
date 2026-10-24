import Link from "next/link";
import ProductCard from "@/components/ProductCard";
import Quiz from "@/components/Quiz";
import ProgramTabs from "@/components/ProgramTabs";
import { getProducts, getSettings } from "@/lib/data";
import { categoryLabel, riyals, shortName } from "@/lib/format";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };

export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/programs", { title: t(lang).programs.title, description: t(lang).programs.metaDesc });
}

const CATS = ["follow", "files", "consult"] as const;
const COMPARE_SLUGS = ["intensive", "advanced", "basic", "nutrition"];

export default async function Programs({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).programs;
  const [products, s] = await Promise.all([getProducts(lang), getSettings(lang)]);
  const compare = COMPARE_SLUGS.map((slug) => products.find((p) => p.slug === slug));
  const showCompare = compare.every(Boolean);

  const quizOffers = Object.fromEntries(products.flatMap((p) => p.offers.map((o) => [o.sku, {
    sku: o.sku, name: p.name, slug: p.slug, price: riyals(o.price_halalas, lang), monthly: o.months === 1,
  }])));

  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,48px)", marginTop: 12 }}>{u.title}</h1>
          <p className="lead">{u.lead}</p>
          <p style={{ marginTop: 16 }}>{u.which} <Link href="#quiz" className="text-link">{u.startQuiz}</Link></p>
        </div>
      </section>

      <section className="section tight">
        <div className="wrap">
          <ProgramTabs
            aria={u.tabsAria}
            labels={Object.fromEntries(CATS.map((c) => [c, categoryLabel(c, lang)])) as Record<(typeof CATS)[number], string>}
            panels={Object.fromEntries(CATS.map((c) => {
              const list = products.filter((p) => p.category === c);
              return [c, list.length
                ? <div className="grid g4">{list.map((p, i) => <ProductCard key={p.id} p={p} index={i} lang={lang} />)}</div>
                : <p className="alert info">{u.empty}</p>];
            })) as Record<(typeof CATS)[number], React.ReactNode>}
          />
          <p className="small muted" style={{ marginTop: 18 }}>{s.prices_note} <Link href={href(lang, "/policies#refund")}>{u.guaranteeLink}</Link></p>
        </div>
      </section>

      {showCompare && (
        <section className="section tight white">
          <div className="wrap">
            <div className="sec-head"><span className="eyebrow">{u.compareEyebrow}</span><h2>{u.compareTitle}</h2></div>
            <p className="compare-hint">{u.compareHint}</p>
            <div className="table-wrap" tabIndex={0} role="region" aria-label={u.compareAria}>
              <table className="t">
                <thead>
                  <tr><th scope="col">{u.includes}</th>{compare.map((p) => <th scope="col" key={p!.slug}>{shortName(p!.name)}</th>)}</tr>
                </thead>
                <tbody>
                  <tr>
                    <th scope="row">{u.monthly}</th>
                    {compare.map((p) => {
                      const m = p!.offers.find((o) => o.months === 1);
                      return <td key={p!.slug} className="num"><b>{m ? riyals(m.price_halalas, lang) : "—"}</b></td>;
                    })}
                  </tr>
                  {u.compare.map(([label, vals]) => (
                    <tr key={label}>
                      <th scope="row">{label}</th>
                      {vals.map((v, i) => <td key={i} className={v.startsWith("✓") ? "yes" : v === "—" ? "no" : ""}>{v}</td>)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="small muted" style={{ marginTop: 12 }}>{u.bookletsNote} <Link href={href(lang, "/booklets")}>{u.bookletsLink}</Link>.</p>
          </div>
        </section>
      )}

      <section className="section" id="quiz">
        <div className="wrap">
          <div className="sec-head"><span className="eyebrow">{u.quizEyebrow}</span><h2>{u.quizTitle}</h2></div>
          <Quiz offers={quizOffers} />
        </div>
      </section>
    </div>
  );
}
