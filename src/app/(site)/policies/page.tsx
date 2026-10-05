import type { Metadata } from "next";
import RichText from "@/components/RichText";
import { getPolicies } from "@/lib/data";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)
export const metadata: Metadata = { title: "السياسات", description: "الشروط والأحكام، والضمان والاسترجاع، وسياسة الخصوصية، وسياسة التقييمات." };

export default async function Policies() {
  const policies = await getPolicies();
  return (
    <>
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">السياسات</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>الشروط والخصوصية والاسترجاع</h1>
          <nav className="row" style={{ marginTop: 18 }} aria-label="أقسام السياسات">
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
    </>
  );
}
