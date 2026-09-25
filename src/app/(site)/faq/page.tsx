import type { Metadata } from "next";
import Link from "next/link";
import RichText from "@/components/RichText";
import { CopyButton } from "@/components/FormBits";
import { getFaqs, getSettings } from "@/lib/data";
import { waLink } from "@/lib/format";

export const revalidate = 300;
export const metadata: Metadata = { title: "الأسئلة الشائعة" };

export default async function Faq() {
  const [faqs, s] = await Promise.all([getFaqs(), getSettings()]);
  return (
    <>
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">الأسئلة الشائعة</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>قبل ما تشترك</h1>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap account-layout">
          <div className="faq">
            {faqs.map((f) => (
              <details key={f.id}>
                <summary>{f.question}</summary>
                <div className="ans"><RichText text={f.answer} /></div>
              </details>
            ))}
          </div>
          <aside className="stack">
            <div className="card">
              <h2 style={{ fontSize: 18, marginBottom: 10 }}>بيانات التحويل</h2>
              <div className="bank">
                <div><span className="muted small">اسم الحساب</span><div>{s.bank.accountName}</div></div>
                <div><span className="muted small">البنك</span><div>{s.bank.bankName}</div></div>
                <div><span className="muted small">الآيبان</span><div className="iban"><bdi>{s.bank.iban}</bdi></div></div>
                <CopyButton value={s.bank.iban} label="نسخ الآيبان" />
              </div>
              <p className="small muted" style={{ marginTop: 10 }}>حوّل فقط بعد إرسال التقييم وظهور رقم طلبك والمبلغ.</p>
            </div>
            <div className="card flat">
              <p>ما لقيت جوابك؟</p>
              <a className="btn btn-block" style={{ marginTop: 10 }} href={waLink(s.contact.whatsapp)} target="_blank" rel="noopener">راسلنا على واتساب</a>
              <Link className="btn btn-ghost btn-block" style={{ marginTop: 8 }} href="/policies">السياسات الكاملة</Link>
            </div>
          </aside>
        </div>
      </section>
    </>
  );
}
