import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getFreePlans } from "@/lib/data";
import { getCurrentUser } from "@/lib/session";
import FreePlanButton from "../FreePlanButton";
import PlanCover from "../PlanCover";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

type P = { params: Promise<{ lang: string; slug: string }> };
const valid = (s: string) => /^[a-z0-9-]{1,60}$/.test(s);

export async function generateMetadata({ params }: P): Promise<Metadata> {
  const { lang: raw, slug } = await params;
  const lang: Lang = isLang(raw) ? raw : "ar";
  const u = t(lang).freePlans;
  const [plan] = valid(slug) ? await getFreePlans(null, slug, lang) : [];
  if (!plan) return { title: u.unavailable, robots: { index: false } };
  return pageMeta(lang, `/free-plans/${plan.slug}`, { title: `${plan.title} ${u.pdfSuffix}`, description: plan.summary.slice(0, 160) });
}

// الجداول المخفية لا تظهر هنا ولا يمكن طلبها (RLS + app.request_free_plan)
export default async function FreePlanPage({ params }: P) {
  const { lang: raw, slug } = await params;
  const lang: Lang = isLang(raw) ? raw : "ar";
  const u = t(lang).freePlans;
  if (!valid(slug)) notFound();
  const user = await getCurrentUser().catch(() => null);
  const [plan] = await getFreePlans(user?.id ?? null, slug, lang);
  if (!plan) notFound();
  return (
    <section className="section tight pub">
      <div className="wrap stack" style={{ ["--space" as string]: "18px", maxWidth: 860 }}>
        <nav className="small"><Link href={href(lang, "/free-plans")}>{u.eyebrow}</Link> / {plan.title}</nav>
        <div className="card fp-detail">
          <PlanCover imageId={plan.image_id} title={plan.title} />
          <div className="stack" style={{ ["--space" as string]: "12px" }}>
            {plan.audience && <span className="tag soft" style={{ width: "fit-content" }}>{plan.audience}</span>}
            <h1 style={{ fontSize: "clamp(26px,4vw,38px)" }}>{plan.title}</h1>
            <p style={{ whiteSpace: "pre-wrap" }}>{plan.summary}</p>
            <FreePlanButton slug={plan.slug} loggedIn={Boolean(user)} owned={plan.owned} />
            <p className="small muted">{u.detailNote}</p>
          </div>
        </div>
        <Link href={href(lang, "/free-plans")}>{u.all}</Link>
      </div>
    </section>
  );
}
