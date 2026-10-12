import type { Metadata } from "next";
import Link from "next/link";
import ProductCard from "@/components/ProductCard";
import Quiz from "@/components/Quiz";
import ProgramTabs from "@/components/ProgramTabs";
import { getProducts, getSettings } from "@/lib/data";
import { CATEGORY_LABEL, riyals, shortName } from "@/lib/format";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)
export const metadata: Metadata = { title: "البرامج والأسعار", description: "باقات المتابعة، والملفات بدون متابعة، والاستشارات — مع الأسعار بالريال السعودي." };

const CATS = ["follow", "files", "consult"] as const;

// جدول المقارنة منقول من صفحة البرامج في الموقع الحالي (السعر يُقرأ من قاعدة البيانات)
const COMPARE: [string, string[]][] = [
  ["خطة تمرين", ["✓", "✓", "✓", "—"]],
  ["خطة تغذية شاملة", ["✓", "✓", "—", "✓"]],
  ["تعليم حساب السعرات", ["✓", "—", "—", "✓"]],
  ["المتابعة", ["أسبوعية", "أسبوعية", "كل أسبوعين", "أسبوعية (تغذية)"]],
  ["مكالمات زوم", ["4 شهرياً", "—", "—", "—"]],
  ["جلسة حضورية لتصحيح التكنيك", ["✓ (للبنات بالشرقية)", "—", "—", "—"]],
  ["شرح MyFitnessPal", ["✓", "—", "—", "—"]],
  ["كتيب الرياضة والتغذية", ["✓", "✓", "✓", "—"]],
  ["تواصل يومي (رد خلال 48 ساعة)", ["✓", "✓", "✓", "✓"]],
  ["مناسبة لـ", ["المبتدئين", "أصحاب الخبرة", "من يحتاج تمرين فقط", "من يحتاج تغذية فقط"]],
];
const COMPARE_SLUGS = ["intensive", "advanced", "basic", "nutrition"];

export default async function Programs() {
  const [products, s] = await Promise.all([getProducts(), getSettings()]);
  const compare = COMPARE_SLUGS.map((slug) => products.find((p) => p.slug === slug));
  const showCompare = compare.every(Boolean);

  const quizOffers = Object.fromEntries(products.flatMap((p) => p.offers.map((o) => [o.sku, {
    sku: o.sku, name: p.name, slug: p.slug, price: riyals(o.price_halalas), monthly: o.months === 1,
  }])));

  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">البرامج</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,48px)", marginTop: 12 }}>البرامج والأسعار</h1>
          <p className="lead">كل البرامج مخصصة حسب الهدف بعد الاستبيان. خصم 10% للطلاب ومجاني لأهل غزة.</p>
          <p style={{ marginTop: 16 }}>أي باقة تناسبني؟ 4 أسئلة تحدد البرنامج المناسب. <Link href="#quiz" className="text-link">بدء الاختبار</Link></p>
        </div>
      </section>

      <section className="section tight">
        <div className="wrap">
          <ProgramTabs
            labels={Object.fromEntries(CATS.map((c) => [c, CATEGORY_LABEL[c]])) as Record<(typeof CATS)[number], string>}
            panels={Object.fromEntries(CATS.map((c) => {
              const list = products.filter((p) => p.category === c);
              return [c, list.length
                ? <div className="grid g4">{list.map((p, i) => <ProductCard key={p.id} p={p} index={i} />)}</div>
                : <p className="alert info">لا توجد منتجات متاحة في هذا القسم حالياً.</p>];
            })) as Record<(typeof CATS)[number], React.ReactNode>}
          />
          <p className="small muted" style={{ marginTop: 18 }}>{s.prices_note} <Link href="/policies#refund">شروط الضمان والتجديد المجاني</Link></p>
        </div>
      </section>

      {showCompare && (
        <section className="section tight white">
          <div className="wrap">
            <div className="sec-head"><span className="eyebrow">مقارنة</span><h2>مقارنة باقات المتابعة</h2></div>
            <p className="compare-hint">سحب الجدول جانبياً يعرض باقي الباقات ←</p>
            <div className="table-wrap">
              <table className="t">
                <thead>
                  <tr><th scope="col">ماذا تشمل</th>{compare.map((p) => <th scope="col" key={p!.slug}>{shortName(p!.name)}</th>)}</tr>
                </thead>
                <tbody>
                  <tr>
                    <th scope="row">السعر الشهري</th>
                    {compare.map((p) => {
                      const m = p!.offers.find((o) => o.months === 1);
                      return <td key={p!.slug} className="num"><b>{m ? riyals(m.price_halalas) : "—"}</b></td>;
                    })}
                  </tr>
                  {COMPARE.map(([label, vals]) => (
                    <tr key={label}>
                      <th scope="row">{label}</th>
                      {vals.map((v, i) => <td key={i} className={v.startsWith("✓") ? "yes" : v === "—" ? "no" : ""}>{v}</td>)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </section>
      )}

      <section className="section" id="quiz">
        <div className="wrap">
          <div className="sec-head"><span className="eyebrow">أي باقة تناسبني؟</span><h2>4 أسئلة تحدد البرنامج المناسب</h2></div>
          <Quiz offers={quizOffers} />
        </div>
      </section>
    </div>
  );
}
