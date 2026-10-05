import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getFreePlans } from "@/lib/data";
import { getCurrentUser } from "@/lib/session";
import FreePlanButton from "../FreePlanButton";
import PlanCover from "../PlanCover";

type P = { params: Promise<{ slug: string }> };
const valid = (s: string) => /^[a-z0-9-]{1,60}$/.test(s);

export async function generateMetadata({ params }: P): Promise<Metadata> {
  const { slug } = await params;
  const [plan] = valid(slug) ? await getFreePlans(null, slug) : [];
  if (!plan) return { title: "جدول غير متاح", robots: { index: false } };
  return { title: `${plan.title} — جدول مجاني PDF`, description: plan.summary.slice(0, 160), alternates: { canonical: `/free-plans/${plan.slug}` } };
}

// الجداول المخفية لا تظهر هنا ولا يمكن طلبها (RLS + app.request_free_plan)
export default async function FreePlanPage({ params }: P) {
  const { slug } = await params;
  if (!valid(slug)) notFound();
  const user = await getCurrentUser().catch(() => null);
  const [plan] = await getFreePlans(user?.id ?? null, slug);
  if (!plan) notFound();
  return (
    <section className="section tight pub">
      <div className="wrap stack" style={{ ["--space" as string]: "18px", maxWidth: 860 }}>
        <nav className="small"><Link href="/free-plans">الجداول المجانية</Link> / {plan.title}</nav>
        <div className="card fp-detail">
          <PlanCover imageId={plan.image_id} title={plan.title} />
          <div className="stack" style={{ ["--space" as string]: "12px" }}>
            {plan.audience && <span className="tag soft" style={{ width: "fit-content" }}>{plan.audience}</span>}
            <h1 style={{ fontSize: "clamp(26px,4vw,38px)" }}>{plan.title}</h1>
            <p style={{ whiteSpace: "pre-wrap" }}>{plan.summary}</p>
            <FreePlanButton slug={plan.slug} loggedIn={Boolean(user)} owned={plan.owned} />
            <p className="small muted">ملف PDF مجاني يُحمّل من حسابك بعد الطلب. الجدول عام وإرشادي؛ استشر مختصاً إذا عندك إصابة أو حالة صحية.</p>
          </div>
        </div>
        <Link href="/free-plans">← كل الجداول المجانية</Link>
      </div>
    </section>
  );
}
