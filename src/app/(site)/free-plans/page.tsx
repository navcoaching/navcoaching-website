import type { Metadata } from "next";
import Link from "next/link";
import { getFreePlans } from "@/lib/data";
import { getCurrentUser } from "@/lib/session";
import FreePlanButton from "./FreePlanButton";
import PlanCover from "./PlanCover";

export const metadata: Metadata = {
  title: "جداول تدريب مجانية PDF",
  description: "جداول تدريب مجانية بصيغة PDF تساعدك تنظّم تمارينك وتبدأ بخطوات واضحة. أنشئ حسابك المجاني، اطلب الجدول المناسب لهدفك، وحمّله من حسابك.",
  alternates: { canonical: "/free-plans" },
};

export default async function FreePlans() {
  const user = await getCurrentUser().catch(() => null);
  const plans = await getFreePlans(user?.id ?? null);
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">الجداول المجانية</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>جداول تدريب مجانية</h1>
          <p className="lead" style={{ maxWidth: 720 }}>
            جداول تدريب مجانية تساعد على تنظيم التمارين والبدء بخطوات واضحة حسب الهدف. إنشاء حساب وطلب الجدول المناسب، ثم تحميل ملف PDF من لوحة التحكم في الحساب.
          </p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap stack" style={{ ["--space" as string]: "22px" }}>
          {plans.length === 0 ? (
            <div className="card stack">
              <p>ما فيه جداول مجانية منشورة حالياً. تابعونا، وبنضيفها قريباً.</p>
              <Link href="/programs" className="btn btn-ghost" style={{ width: "fit-content" }}>تصفّح البرامج</Link>
            </div>
          ) : (
            <ul className="fp-grid" data-testid="free-plans">
              {plans.map((p) => (
                <li key={p.id} className="card fp-card">
                  <PlanCover imageId={p.image_id} title={p.title} />
                  <div className="fp-body">
                    {p.audience && <span className="tag soft">{p.audience}</span>}
                    <h2><Link href={`/free-plans/${p.slug}`}>{p.title}</Link></h2>
                    <p className="muted">{p.summary}</p>
                  </div>
                  <FreePlanButton slug={p.slug} loggedIn={Boolean(user)} owned={p.owned} />
                </li>
              ))}
            </ul>
          )}
          <p className="small muted">
            الجداول إرشادية وعامة، وقد لا تناسب كل شخص. في حال وجود إصابة أو حالة صحية يُنصح باستشارة مختص قبل البدء. وللبرنامج المصمم حسب الهدف مع متابعة: <Link href="/programs">البرامج</Link>.
          </p>
        </div>
      </section>
    </div>
  );
}
