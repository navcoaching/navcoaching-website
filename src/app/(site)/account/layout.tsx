import { getCurrentUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import AccountNav, { type AccountLink } from "@/components/account/AccountNav";

/** قائمة جانبية لحساب المتدرب (مثل لوحة الإدارة): طلباتي، التمرين، التغذية والمكملات، المراجعة */
export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await getCurrentUser();
  if (!user) return children; // الصفحات نفسها تحوّل لتسجيل الدخول
  // الاشتراك الحالي: أحدث طلب متابعة فعّال (النشط أولاً)
  const cur = await withUser(user.id, async (tx) => (await tx.query(
    `SELECT o.order_no,
            EXISTS (SELECT 1 FROM blocks b WHERE b.order_id = o.id) AS training,
            (EXISTS (SELECT 1 FROM nutrition_targets t WHERE t.order_id = o.id)
              OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.order_id = o.id AND NOT p.archived)
              OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.order_id = o.id AND NOT r.archived)) AS nutrition
       FROM orders o
      WHERE o.user_id = $1 AND o.category = 'follow' AND o.status IN ('active', 'delivered', 'completed')
      ORDER BY (o.status = 'active') DESC, o.sub_start_at DESC NULLS LAST, o.created_at DESC LIMIT 1`, [user.id])).rows[0] as
    { order_no: string; training: boolean; nutrition: boolean } | undefined);
  const base = cur ? `/account/orders/${cur.order_no}` : null;
  const links: AccountLink[] = [
    { href: "/account", label: "طلباتي", icon: "🧾", exact: true },
    { href: base && cur?.training ? `${base}/training` : null, label: "جدول التمرين", icon: "🏋️" },
    { href: base ? `${base}/progress` : null, label: "التقدم", icon: "📈" },
    { href: base && cur?.nutrition ? `${base}/nutrition` : null, label: "التغذية والمكملات", icon: "🥗" },
    { href: base && cur?.nutrition ? `${base}/nutrition/log` : null, label: "سجل الماكروز", icon: "📊" },
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
