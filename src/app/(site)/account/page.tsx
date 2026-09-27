import type { Metadata } from "next";
import Link from "next/link";
import { requireUser } from "@/lib/session";
import { getMyFreePlans, getMyOrders, getMyPrefs } from "@/lib/data";
import { fmtDate, riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import { PrefsForm, ProfileForm, SignOut } from "./ClientForms";
import MyProgram from "@/components/account/MyProgram";
import EndOfProgramList from "@/components/account/EndOfProgram";

export const metadata: Metadata = { title: "حسابي", robots: { index: false } };

export default async function Account({ searchParams }: { searchParams: Promise<{ denied?: string; plan?: string }> }) {
  const user = await requireUser("/account");
  const [orders, prefs, freePlans, { denied, plan: planMsg }] = await Promise.all([getMyOrders(user.id), getMyPrefs(user.id), getMyFreePlans(user.id), searchParams]);
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
          <EndOfProgramList userId={user.id} name={user.name} orders={orders} />
          <MyProgram userId={user.id} orders={orders} />
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
          {(freePlans.length > 0 || planMsg) && <section id="free-plans" className="stack" aria-labelledby="fp-h" style={{ ["--space" as string]: "12px", scrollMarginTop: 90 }}>
            <h2 id="fp-h" style={{ fontSize: 22 }}>جداولي المجانية</h2>
            {planMsg === "unavailable" && <p className="alert warn" role="alert">ملف هذا الجدول غير متاح مؤقتاً. حاول لاحقاً، وإذا استمرت المشكلة راسلنا على واتساب.</p>}
            {planMsg === "notfound" && <p className="alert err" role="alert">تعذّر تحميل الملف: الرابط غير صالح أو لا يخص حسابك.</p>}
            {freePlans.length === 0 ? null : (
              <ul className="fp-mine" data-testid="my-free-plans">
                {freePlans.map((p) => (
                  <li key={p.request_id}>
                    <b>{p.title}</b>
                    <span className="small muted">{p.summary.length > 140 ? p.summary.slice(0, 140) + "…" : p.summary}</span>
                    <span className="small muted">طُلب في {fmtDate(p.requested_at)}</span>
                    {p.has_file
                      ? <a className="btn btn-sm" style={{ width: "fit-content" }} href={`/api/free-plans/${p.request_id}`}>تحميل PDF</a>
                      : <span className="small alert warn" style={{ width: "fit-content" }}>الملف غير متاح مؤقتاً</span>}
                  </li>
                ))}
              </ul>
            )}
          </section>}
        </div>
        <aside className="stack">
          <div className="card stack">
            <h2 style={{ fontSize: 18 }}>بياناتي</h2>
            <p className="small muted">البريد: <bdi dir="ltr">{user.email}</bdi></p>
            <ProfileForm name={user.name.includes("@") ? "" : user.name} />
          </div>
          <div className="card stack" aria-labelledby="prefs-h">
            <h2 id="prefs-h" style={{ fontSize: 18 }}>تفضيلات التواصل</h2>
            <PrefsForm email={prefs.email_enabled} whatsapp={prefs.whatsapp_enabled} />
          </div>
          <Link href="/install" className="card flat install-cta" data-testid="install-link">
            <b>📱 أضف الموقع كتطبيق على جوالك</b>
            <span className="small muted">خطوات مصوّرة لـ iPhone وأندرويد</span>
          </Link>
          <div className="card flat stack">
            <p className="small">تحتاج مساعدة؟ راسلنا على واتساب واذكر رقم طلبك.</p>
            <SignOut />
          </div>
        </aside>
      </div>
    </section>
  );
}
