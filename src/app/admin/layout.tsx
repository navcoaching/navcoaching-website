import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";
import { requireCoach } from "@/lib/session";

export const metadata: Metadata = { title: { default: "لوحة الإدارة", template: "%s — لوحة الإدارة" }, robots: { index: false } };
export const dynamic = "force-dynamic";

const NAV = [
  ["/admin", "الرئيسية"], ["/admin/orders", "الطلبات"], ["/admin/members", "الأعضاء"], ["/admin/packages", "الباقات والمتدربين"], ["/admin/products", "المنتجات"], ["/admin/exercises", "مكتبة التمارين"], ["/admin/templates", "قوالب البرامج"], ["/admin/free-plans", "الجداول المجانية"], ["/admin/reviews", "التقييمات"],
  ["/admin/content", "المحتوى والإعدادات"], ["/admin/media", "الصور"], ["/", "الموقع ↗"],
];

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  await requireCoach();
  return (
    <div className="admin">
      <nav className="admin-side" aria-label="لوحة الإدارة">
        <Link href="/admin" className="brand"><Image src="/brand/logo-white.webp" alt="Nav Coaching" width={130} height={28} /></Link>
        {NAV.map(([href, label]) => <Link key={href} href={href}>{label}</Link>)}
      </nav>
      <main className="admin-main" id="main">{children}</main>
    </div>
  );
}
