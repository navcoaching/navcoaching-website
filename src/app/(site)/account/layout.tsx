import { getCurrentUser } from "@/lib/session";
import { loadCurrentOrder } from "@/lib/current-order";
import AccountNav, { type AccountLink } from "@/components/account/AccountNav";

/** قائمة جانبية لحساب المتدرب (مثل لوحة الإدارة): طلباتي، التمرين، التغذية والمكملات، المراجعة */
export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) return children; // الصفحات نفسها تحوّل لتسجيل الدخول
  const cur = await loadCurrentOrder(user.id);
  const base = cur ? `/account/orders/${cur.order_no}` : null;
  const links: AccountLink[] = [
    { href: "/account", label: "طلباتي", icon: "orders", exact: true },
    { href: base && cur?.training ? `${base}/training` : null, label: "جدول التمرين", icon: "training" },
    { href: base ? `${base}/progress` : null, label: "التقدم", icon: "progress" },
    { href: base && cur?.nutrition ? `${base}/nutrition` : null, label: "التغذية والمكملات", icon: "nutrition" },
    { href: base ? `${base}#checkin` : null, label: "المراجعة الأسبوعية", icon: "checkin", daily: false },
    { href: "/account/guide", label: "دليل الاستخدام", icon: "guide", daily: false },
  ];
  return (
    <div className="account-shell app">
      <AccountNav links={links} />
      <div className="account-content">{children}</div>
    </div>
  );
}
