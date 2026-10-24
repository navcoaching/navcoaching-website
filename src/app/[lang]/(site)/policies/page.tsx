import RichText from "@/components/RichText";
import { getPolicies } from "@/lib/data";
import { isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/policies", { title: t(lang).policies.metaTitle, description: t(lang).policies.metaDesc });
}

export default async function Policies({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).policies;
  const policies = await getPolicies(lang);
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{u.title}</h1>
          <nav className="row" style={{ marginTop: 18 }} aria-label={u.sectionsAria}>
            {policies.map((p) => <a key={p.slug} className="btn btn-ghost btn-sm" href={`#${p.slug}`}>{p.title}</a>)}
          </nav>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap stack" style={{ ["--space" as string]: "22px", maxWidth: 860 }}>
          {policies.map((p) => (
            <article key={p.slug} id={p.slug} className="card">
              <h2 style={{ fontSize: 24, marginBottom: 14 }}>{p.title}</h2>
              <RichText text={p.body} />
            </article>
          ))}
        </div>
      </section>
    </div>
  );
}
