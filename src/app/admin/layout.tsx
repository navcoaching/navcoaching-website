import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";
import { requireCoach } from "@/lib/session";
import AdminNav from "@/components/admin/AdminNav";
import ThemeToggle from "@/components/ThemeToggle";

export const metadata: Metadata = { title: { default: "لوحة الإدارة", template: "%s — لوحة الإدارة" }, robots: { index: false } };
export const dynamic = "force-dynamic";

// مجموعات القائمة الجانبية: كل مجموعة تجمع الصفحات المتعلقة ببعض
const NAV: { title?: string; links: [string, string][] }[] = [
  { links: [["/admin", "الرئيسية"]] },
  { title: "المتدربين والطلبات", links: [["/admin/orders", "الطلبات"], ["/admin/checkins", "المراجعات الأسبوعية"], ["/admin/members", "الأعضاء"], ["/admin/packages", "الباقات والمتدربين"]] },
  { title: "التمرين", links: [["/admin/templates", "قوالب البرامج"], ["/admin/exercises", "مكتبة التمارين"], ["/admin/rehab", "التمارين التأهيلية"]] },
  { title: "التغذية", links: [["/admin/nutrition", "التغذية والمكملات"], ["/admin/foods", "قاعدة الأكل"], ["/admin/foods/guide", "دليل مصادر الأكل"]] },
  { title: "المتجر والموقع", links: [["/admin/products", "المنتجات"], ["/admin/free-plans", "الجداول المجانية"], ["/admin/booklets", "الكتيبات"], ["/admin/reviews", "التقييمات"], ["/admin/media", "الصور"]] },
  { title: "الإعدادات", links: [["/admin/content", "المحتوى والإعدادات"], ["/admin/content/intake", "أسئلة الاستبيان"], ["/", "الموقع ↗"]] },
];

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  await requireCoach();
  return (
    <div className="admin app">
      <nav className="admin-side" aria-label="لوحة الإدارة">
        <Link href="/admin" className="brand">
          <Image className="l-light" src="/brand/logo-color.webp" alt="Nav Coaching" width={130} height={28} />
          <Image className="l-dark" src="/brand/logo-white.webp" alt="Nav Coaching" width={130} height={28} />
        </Link>
        <div className="admin-theme" data-testid="admin-theme"><ThemeToggle withLabel /></div>
        <AdminNav groups={NAV} />
      </nav>
      <main className="admin-main" id="main">{children}</main>
    </div>
  );
}
