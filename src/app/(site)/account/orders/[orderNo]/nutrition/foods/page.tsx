import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import FoodGuide, { loadGuideFoods, type GuideSP } from "@/components/nutrition/FoodGuide";

export const metadata: Metadata = { title: "دليل مصادر الأكل", robots: { index: false } };

/** دليل مصادر الأكل للمتدرب: الأنواع (لحوم حمراء، دواجن، أسماك، بقوليات...) والقيم (عالي الألياف، غني بالفيتامينات...) */
export default async function FoodGuidePage({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<GuideSP> }) {
  const { orderNo } = await params;
  const sp = await searchParams;
  const user = await requireUser(`/account/orders/${orderNo}/nutrition/foods`);
  const data = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT order_no, user_id, status FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o || o.user_id !== user.id) return null;
    // مثل باقي التغذية: يظهر بعد تأكيد الاشتراك
    const entitled = ["active", "delivered", "completed"].includes(o.status);
    return { o, foods: entitled ? await loadGuideFoods(tx) : [] };
  });
  if (!data) notFound();
  const { o, foods } = data;
  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <Link href={`/account/orders/${o.order_no}/nutrition`}>التغذية والمكملات</Link> / دليل مصادر الأكل</nav>
        <h1 style={{ fontSize: "clamp(24px,4vw,32px)", margin: 0 }}>دليل مصادر الأكل</h1>
        <p className="muted" style={{ margin: 0 }}>اختار نوع المصدر أو القيمة الغذائية اللي تبيها، واضغط على أي صنف عشان تشوف الألياف والفيتامينات والمعادن فيه.</p>
        {foods.length === 0
          ? <p className="card muted">الدليل يظهر بعد تأكيد اشتراكك.</p>
          : <FoodGuide foods={foods} sp={sp} base={`/account/orders/${o.order_no}/nutrition/foods`} />}
      </div>
    </section>
  );
}
