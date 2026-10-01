import type { Metadata } from "next";
import Link from "next/link";
import { requireUser } from "@/lib/session";
import { getMyBooklets, getMyFreePlans, getMyOrders, getMyPrefs } from "@/lib/data";
import { fmtDate, riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import { PrefsForm, ProfileForm, SignOut } from "./ClientForms";
import PushCard from "@/components/account/PushCard";
import InstallPrompt from "@/components/account/InstallPrompt";
import { pushPublicKey } from "@/lib/push";
import MyProgram from "@/components/account/MyProgram";
import EndOfProgramList from "@/components/account/EndOfProgram";

export const metadata: Metadata = { title: "حسابي", robots: { index: false } };

const PAST = ["completed", "cancelled"];
const IN_PROGRAM = ["active", "delivered"];

export default async function Account({ searchParams }: { searchParams: Promise<{ denied?: string; plan?: string; booklet?: string }> }) {
  const user = await requireUser("/account");
  const [orders, prefs, freePlans, booklets, { denied, plan: planMsg, booklet: bookletMsg }] = await Promise.all([
    getMyOrders(user.id), getMyPrefs(user.id), getMyFreePlans(user.id), getMyBooklets(user.id), searchParams]);
  // الطلبات المكتملة والملغاة تنطوي تحت «طلبات سابقة»
  const past = orders.filter((o) => PAST.includes(o.status));
  // الطلبات الفعّالة تظهر في «برنامجي» فوق، فما نكررها هنا (توفير مساحة على الجوال)
  const inProgram = orders.filter((o) => IN_PROGRAM.includes(o.status));
  const current = orders.filter((o) => !PAST.includes(o.status) && !IN_PROGRAM.includes(o.status));
  const needsAction = orders.filter((o) => ["awaiting_payment", "awaiting_quote"].includes(o.status));

  return (
    <section className="section tight">
      <div className="wrap account-layout account-home">
        <div className="stack" style={{ ["--space" as string]: "18px" }}>
          <div>
            <span className="eyebrow">حسابي</span>
            <h1 style={{ fontSize: "clamp(26px,4vw,36px)", marginTop: 8 }}>أهلاً {user.name.includes("@") ? "" : user.name.split(" ")[0]}</h1>
          </div>
          <InstallPrompt />
          {denied && <p className="alert warn">لوحة الإدارة للمدربة فقط.</p>}
          {needsAction.length > 0 && <p className="alert warn">عندك {needsAction.length === 1 ? "طلب يحتاج" : `${needsAction.length} طلبات تحتاج`} إجراء منك.</p>}
          <EndOfProgramList userId={user.id} name={user.name} orders={orders} />
          <MyProgram userId={user.id} orders={orders} />
          {(booklets.length > 0 || bookletMsg) && <section id="booklets" className="card stack" aria-labelledby="bk-h" style={{ ["--space" as string]: "12px", scrollMarginTop: 90 }} data-testid="booklets">
            <h2 id="bk-h" style={{ fontSize: 20 }}>📘 تحميل الكتيبات</h2>
            {bookletMsg === "unavailable" && <p className="alert warn" role="alert">الملف غير متاح مؤقتاً. جرّب لاحقاً، وإذا استمرت المشكلة راسلنا على واتساب.</p>}
            {bookletMsg === "notfound" && <p className="alert err" role="alert">تعذّر التحميل: الكتيب غير موجود أو غير متاح لحسابك.</p>}
            <ul className="stack" style={{ ["--space" as string]: "10px", listStyle: "none", margin: 0, padding: 0 }}>
              {booklets.map((b) => (
                <li key={b.id} className="row" style={{ justifyContent: "space-between", gap: 10, flexWrap: "wrap" }}>
                  <span className="stack" style={{ ["--space" as string]: "2px" }}>
                    <b>{b.title}</b>
                    {b.description && <span className="small muted">{b.description}</span>}
                  </span>
                  <a className="btn btn-sm" href={`/api/booklets/${b.id}`}>تحميل PDF <span className="small">({(b.file_size / 1024 / 1024).toFixed(1)} م.ب)</span></a>
                </li>
              ))}
            </ul>
          </section>}
          <h2 style={{ fontSize: 22 }}>طلباتي</h2>
          {orders.length === 0 ? (
            <div className="card stack">
              <p>ما عندك طلبات حتى الآن.</p>
              <Link href="/programs" className="btn" style={{ width: "fit-content" }}>تصفح البرامج</Link>
            </div>
          ) : (
            <>
              {current.map((o) => <OrderCard key={o.id} o={o} />)}
              {current.length === 0 && (
                <p className="small muted" style={{ margin: 0 }} data-testid="orders-in-program">
                  {inProgram.length ? "طلبك الحالي في «برنامجي» فوق، وتفاصيله من «تفاصيل الطلب والمراجعات»." : "ما عندك طلبات حالية."}
                </p>
              )}
              {past.length > 0 && (
                <details className="card flat past-orders" data-testid="past-orders">
                  <summary>طلبات سابقة ({past.length}) <span className="small muted">مكتملة أو ملغاة</span></summary>
                  <div className="stack" style={{ ["--space" as string]: "12px", marginTop: 12 }}>
                    {past.map((o) => <OrderCard key={o.id} o={o} />)}
                  </div>
                </details>
              )}
            </>
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
        <aside className="account-settings" aria-labelledby="settings-h">
          <h2 id="settings-h" className="settings-title">إعدادات الحساب</h2>
          <div className="card stack">
            <h2 style={{ fontSize: 18 }}>بياناتي</h2>
            <p className="small muted">البريد: <bdi dir="ltr">{user.email}</bdi></p>
            <ProfileForm name={user.name.includes("@") ? "" : user.name} />
          </div>
          <div className="card stack" aria-labelledby="prefs-h">
            <h2 id="prefs-h" style={{ fontSize: 18 }}>تفضيلات التواصل</h2>
            <PrefsForm email={prefs.email_enabled} whatsapp={prefs.whatsapp_enabled} push={pushPublicKey() ? prefs.push_enabled : null} />
          </div>
          {pushPublicKey() && <PushCard publicKey={pushPublicKey()} />}
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

/** بطاقة طلب في «طلباتي» */
function OrderCard({ o }: { o: Awaited<ReturnType<typeof getMyOrders>>[number] }) {
  return (
    <Link href={`/account/orders/${o.order_no}`} className="card order-card">
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
  );
}
