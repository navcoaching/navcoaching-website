import Link from "next/link";
import Image from "next/image";
import type { Settings } from "@/lib/data";
import { localPhone, waLink } from "@/lib/format";
import { IconWhatsApp } from "./Icons";

export default function Footer({ s }: { s: Settings }) {
  return (
    <>
      <footer className="site-footer">
        <div className="wrap">
          <div className="foot-grid">
            <div className="stack" style={{ ["--space" as string]: "14px" }}>
              <Image src="/brand/logo-white.webp" alt="Nav Coaching" width={150} height={34} />
              <p>برامج تدريب وتغذية مخصصة لأهدافك، مع متابعة أسبوعية.</p>
              <p className="small">ساعات العمل والرد: {s.response_time}</p>
            </div>
            <div>
              <h2>الموقع</h2>
              <ul>
                <li><Link href="/programs">البرامج والأسعار</Link></li>
                <li><Link href="/about">عن المدربة</Link></li>
                <li><Link href="/reviews">تجارب المتدربين</Link></li>
                <li><Link href="/faq">الأسئلة الشائعة</Link></li>
                <li><Link href="/account">حسابي وطلباتي</Link></li>
              </ul>
            </div>
            <div>
              <h2>التواصل والسياسات</h2>
              <ul>
                <li><a href={waLink(s.contact.whatsapp)} rel="noopener" target="_blank">واتساب <bdi>{localPhone(s.contact.whatsapp)}</bdi></a></li>
                {s.contact.instagram && <li><a href={s.contact.instagram} rel="noopener" target="_blank">انستقرام</a></li>}
                <li><Link href="/policies#privacy">سياسة الخصوصية</Link></li>
                <li><Link href="/policies#terms">الشروط والأحكام</Link></li>
                <li><Link href="/policies#refund">الضمان والاسترجاع</Link></li>
                <li><Link href="/policies#reviews">سياسة التقييمات</Link></li>
              </ul>
            </div>
          </div>
          <div className="foot-legal">
            <span>{s.legal.name} · السجل التجاري: <bdi>{s.legal.cr}</bdi></span>
            <span>© Nav Coaching · جميع الحقوق محفوظة</span>
          </div>
        </div>
      </footer>
      <a className="wa-float" href={waLink(s.contact.whatsapp)} target="_blank" rel="noopener" aria-label="تواصل على واتساب"><IconWhatsApp /></a>
    </>
  );
}
