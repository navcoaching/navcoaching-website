import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";
import { requireCoach } from "@/lib/session";

export const metadata: Metadata = { title: { default: "لوحة الإدارة", template: "%s — لوحة الإدارة" }, robots: { index: false } };
export const dynamic = "force-dynamic";

// مجموعات القائمة الجانبية: كل مجموعة تجمع الصفحات المتعلقة ببعض
const NAV: { title?: string; links: [string, string][] }[] = [
  { links: [["/admin", "الرئيسية"]] },
  { title: "المتدربين والطلبات", links: [["/admin/orders", "الطلبات"], ["/admin/members", "الأعضاء"], ["/admin/packages", "الباقات والمتدربين"]] },
  { title: "التمرين", links: [["/admin/templates", "قوالب البرامج"], ["/admin/exercises", "مكتبة التمارين"], ["/admin/rehab", "التمارين التأهيلية"]] },
  { title: "التغذية", links: [["/admin/nutrition", "التغذية والمكملات"], ["/admin/foods", "قاعدة الأكل"]] },
  { title: "المتجر والموقع", links: [["/admin/products", "المنتجات"], ["/admin/free-plans", "الجداول المجانية"], ["/admin/reviews", "التقييمات"], ["/admin/media", "الصور"]] },
  { title: "الإعدادات", links: [["/admin/content", "المحتوى والإعدادات"], ["/", "الموقع ↗"]] },
];

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  await requireCoach();
  return (
    <div className="admin">
      <nav className="admin-side" aria-label="لوحة الإدارة">
        <Link href="/admin" className="brand"><Image src="/brand/logo-white.webp" alt="Nav Coaching" width={130} height={28} /></Link>
        {NAV.map((g, i) => (
          <div key={i} className="nav-group" role={g.title ? "group" : undefined} aria-labelledby={g.title ? `nav-g${i}` : undefined}>
            {g.title && <span className="nav-title" id={`nav-g${i}`}>{g.title}</span>}
            {g.links.map(([href, label]) => <Link key={href} href={href}>{label}</Link>)}
          </div>
        ))}
      </nav>
      <main className="admin-main" id="main">{children}</main>
    </div>
  );
}
