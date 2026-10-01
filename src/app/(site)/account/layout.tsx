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
    { href: "/account", label: "طلباتي", icon: "🧾", exact: true },
    { href: base && cur?.training ? `${base}/training` : null, label: "جدول التمرين", icon: "🏋️" },
    { href: base ? `${base}/progress` : null, label: "التقدم", icon: "📈" },
    { href: base && cur?.nutrition ? `${base}/nutrition` : null, label: "التغذية والمكملات", icon: "🥗" },
    { href: base && cur?.nutrition ? `${base}/nutrition/log` : null, label: "سجل الماكروز", icon: "📊" },
    { href: base && cur?.nutrition ? `${base}/nutrition/foods` : null, label: "دليل مصادر الأكل", icon: "🥦" },
    { href: base ? `${base}#checkin` : null, label: "المراجعة الأسبوعية", icon: "📝" },
    { href: cur ? "/account#instructions" : null, label: "التعليمات", icon: "📋" },
  { href: "/account/guide", label: "دليل الاستخدام", icon: "📖" },
  ];
  return (
    <div className="account-shell">
      <AccountNav links={links} />
      <div className="account-content">{children}</div>
    </div>
  );
}
