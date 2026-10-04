import type { Metadata } from "next";
import Link from "next/link";
import ReviewCard from "@/components/ReviewCard";
import { getPublicReviews, getSettings } from "@/lib/data";

export const revalidate = 300;
export const metadata: Metadata = { title: "تقييمات المتدربين", description: "تجارب حقيقية لمتدربين مع برامج التدريب والتغذية في Nav Coaching، تُنشر بموافقتهم وبدون تعديل." };

export default async function Reviews() {
  const [reviews, s] = await Promise.all([getPublicReviews(), getSettings()]);
  return (
    <>
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">التقييمات</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>تقييمات المتدربين</h1>
          <p className="lead">{s.testimonials_disclaimer}</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap">
          <div className="reviews">{reviews.map((r) => <ReviewCard key={r.id} r={r} />)}</div>
          <p className="small muted">كل تقييم يُراجع قبل النشر ولا يُعدّل نصه. <Link href="/policies#reviews">سياسة التقييمات</Link></p>
        </div>
      </section>
    </>
  );
}
