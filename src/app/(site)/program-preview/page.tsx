import type { Metadata } from "next";
import Link from "next/link";
import Shots from "@/components/Shots";
import { getSettings } from "@/lib/data";

export const metadata: Metadata = {
  title: "نظرة داخل البرنامج",
  description: "لقطات من لوحة المتدرب في Nav Coaching ببيانات مثال: برنامجي، تسجيل التمرين، التغذية اليومية، ولوحة التقدم.",
};
export const revalidate = 3600;

/** معاينة لوحة المتدرب (انتقلت من الرئيسية) */
export default async function ProgramPreview() {
  const s = await getSettings();
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">نظرة داخل برنامج المتدرب</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>كيف يبدو البرنامج من الداخل؟</h1>
          <p className="lead">لقطات من لوحة المتدرب ببيانات مثال، بدون أي بيانات شخصية. الضغط على الصورة يكبّرها.</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap">
          <Shots shots={s.program_shots} />
          <p style={{ marginTop: 24 }}><Link href="/programs" className="btn">البرامج والأسعار</Link></p>
        </div>
      </section>
    </div>
  );
}
