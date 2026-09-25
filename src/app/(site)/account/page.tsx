import type { Metadata } from "next";
import Link from "next/link";
import { requireUser } from "@/lib/session";
import { getMyOrders } from "@/lib/data";
import { fmtDate, riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import { ProfileForm, SignOut } from "./ClientForms";

export const metadata: Metadata = { title: "حسابي", robots: { index: false } };

export default async function Account({ searchParams }: { searchParams: Promise<{ denied?: string }> }) {
  const user = await requireUser("/account");
  const [orders, { denied }] = await Promise.all([getMyOrders(user.id), searchParams]);
  const needsAction = orders.filter((o) => ["awaiting_payment", "awaiting_quote"].includes(o.status));

  return (
    <section className="section tight">
      <div className="wrap account-layout">
        <div className="stack" style={{ ["--space" as string]: "18px" }}>
          <div>
            <span className="eyebrow">حسابي</span>
            <h1 style={{ fontSize: "clamp(26px,4vw,36px)", marginTop: 8 }}>أهلاً {user.name.includes("@") ? "" : user.name.split(" ")[0]}</h1>
          </div>
          {denied && <p className="alert warn">لوحة الإدارة للمدربة فقط.</p>}
          {needsAction.length > 0 && <p className="alert warn">عندك {needsAction.length === 1 ? "طلب يحتاج" : `${needsAction.length} طلبات تحتاج`} إجراء منك.</p>}
          <h2 style={{ fontSize: 22 }}>طلباتي</h2>
          {orders.length === 0 ? (
            <div className="card stack">
              <p>ما عندك طلبات حتى الآن.</p>
              <Link href="/programs" className="btn" style={{ width: "fit-content" }}>تصفح البرامج</Link>
            </div>
          ) : (
            orders.map((o) => (
              <Link key={o.id} href={`/account/orders/${o.order_no}`} className="card order-card">
                <div className="top">
                  <b style={{ fontFamily: "var(--f-display)", fontSize: 18 }}>{o.product_name}</b>
                  <span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span>
                </div>
                <dl className="kv small">
                  <dt>رقم الطلب</dt><dd><bdi className="num">{o.order_no}</bdi></dd>
                  <dt>المدة</dt><dd>{o.offer_label}</dd>
                  <dt>التاريخ</dt><dd>{fmtDate(o.created_at)}</dd>
                  <dt>المبلغ</dt><dd className="num">{o.amount_due_halalas == null ? "بانتظار التأكيد" : riyals(o.amount_due_halalas)}</dd>
                </dl>
              </Link>
            ))
          )}
        </div>
        <aside className="stack">
          <div className="card stack">
            <h2 style={{ fontSize: 18 }}>بياناتي</h2>
            <p className="small muted">البريد: <bdi dir="ltr">{user.email}</bdi></p>
            <ProfileForm name={user.name.includes("@") ? "" : user.name} />
          </div>
          <div className="card flat stack">
            <p className="small">تحتاج مساعدة؟ راسلنا على واتساب واذكر رقم طلبك.</p>
            <SignOut />
          </div>
        </aside>
      </div>
    </section>
  );
}
