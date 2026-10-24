import Link from "next/link";
import { getFreePlans } from "@/lib/data";
import { getCurrentUser } from "@/lib/session";
import FreePlanButton from "./FreePlanButton";
import PlanCover from "./PlanCover";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/free-plans", { title: t(lang).freePlans.metaTitle, description: t(lang).freePlans.metaDesc });
}

export default async function FreePlans({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).freePlans;
  const user = await getCurrentUser().catch(() => null);
  const plans = await getFreePlans(user?.id ?? null, undefined, lang);
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{u.title}</h1>
          <p className="lead" style={{ maxWidth: 720 }}>{plans.length ? u.lead : u.leadEmpty}</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap stack" style={{ ["--space" as string]: "22px" }}>
          {plans.length === 0 ? (
            <div className="card stack">
              <p>{u.empty}</p>
              <div className="row" style={{ gap: "8px 24px" }}>
                <Link href={href(lang, "/calculator")} className="btn" style={{ width: "fit-content" }}>{u.calculator}</Link>
                <Link href={href(lang, "/programs")} className="text-link">{u.pricing}</Link>
              </div>
            </div>
          ) : (
            <ul className="fp-grid" data-testid="free-plans">
              {plans.map((p) => (
                <li key={p.id} className="card fp-card">
                  <PlanCover imageId={p.image_id} title={p.title} />
                  <div className="fp-body">
                    {p.audience && <span className="tag soft">{p.audience}</span>}
                    <h2><Link href={href(lang, `/free-plans/${p.slug}`)}>{p.title}</Link></h2>
                    <p className="muted">{p.summary}</p>
                  </div>
                  <FreePlanButton slug={p.slug} loggedIn={Boolean(user)} owned={p.owned} />
                </li>
              ))}
            </ul>
          )}
          <p className="small muted">{u.note} <Link href={href(lang, "/programs")}>{u.programs}</Link>.</p>
        </div>
      </section>
    </div>
  );
}
