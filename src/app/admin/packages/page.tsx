import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { loadReminders } from "@/lib/reminders";
import { SUB_LABEL, type SubState, daysBetween, fmtYMD, riyadhDate, subscriptionState } from "@/lib/schedule";
import PackageTag from "@/components/admin/PackageTag";
import { CATEGORY_LABEL } from "@/lib/format";

// الحالة لكل طلب: للباقات ذات المدة = حالة الاشتراك (انظري lib/schedule.ts)،
// وللملفات والاستشارات (بدون مدة) = مسلّم / قيد التنفيذ / ملغى.
type Row = {
  order_no: string; user_id: string; contact_name: string; product_id: string | null; product_name: string; current_name: string | null;
  months: number; status: string; sub_start_at: string | null; sub_end_at: string | null; created_at: string;
};
type State = SubState | "delivered" | "in_progress";
const LABEL: Record<State, string> = { ...SUB_LABEL, delivered: "مسلّم / مكتمل", in_progress: "قيد التنفيذ" };
const SUB_STATES: State[] = ["active", "ending_soon", "expired", "cancelled", "not_started"];
const ONE_OFF_STATES: State[] = ["in_progress", "delivered", "cancelled"];
const TONE: Partial<Record<State, string>> = { active: "ok", ending_soon: "action", expired: "muted", cancelled: "muted", not_started: "wait", delivered: "ok", in_progress: "wait" };

export default async function Packages({ searchParams }: { searchParams: Promise<{ pkg?: string; state?: string; q?: string }> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const { rows, products, soon } = await withUser(coach.id, async (tx) => {
    const r = await loadReminders(tx);
    return {
      soon: Math.max(...r.sub_expiry_days),
      rows: (await tx.query(
        `SELECT o.order_no, o.user_id, o.contact_name, o.product_id, o.product_name, p.name AS current_name, o.months, o.status,
                o.sub_start_at, o.sub_end_at, o.created_at
           FROM orders o LEFT JOIN products p ON p.id = o.product_id
          WHERE NOT o.is_demo AND o.archived_at IS NULL ORDER BY o.created_at DESC`)).rows as Row[],
      products: (await tx.query(
        `SELECT id, name, category, status FROM products WHERE status = 'published' OR id IN (SELECT product_id FROM orders WHERE product_id IS NOT NULL)
          ORDER BY category, sort`)).rows as { id: string; name: string; category: string; status: string }[],
    };
  });
  const today = riyadhDate();
  const stateOf = (o: Row): State => o.months > 0
    ? subscriptionState(o, soon, today)
    : o.status === "cancelled" ? "cancelled" : ["delivered", "completed"].includes(o.status) ? "delivered" : "in_progress";

  const withState = rows.map((o) => ({ ...o, state: stateOf(o) }));
  const q = (sp.q ?? "").trim();
  const filtered = withState.filter((o) =>
    (!sp.pkg || o.product_id === sp.pkg) &&
    (!sp.state || o.state === sp.state) &&
    (!q || o.contact_name.includes(q) || o.order_no.toLowerCase().includes(q.toLowerCase())));
  const link = (over: Record<string, string>) => `/admin/packages?${new URLSearchParams(Object.entries({ pkg: sp.pkg ?? "", state: sp.state ?? "", q, ...over }).filter(([, v]) => v))}`;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>الباقات والمتدربين</h1>
      <p className="small muted">
        العدد = متدربون مختلفون (قد يكون للمتدرب أكثر من طلب). «فعّال» = اليوم بين تاريخ البدء والانتهاء؛ «قريب من الانتهاء» = متبقٍ {soon} أيام أو أقل (من إعدادات التذكيرات)؛
        «منتهٍ» = بعد تاريخ الانتهاء أو الطلب مكتمل؛ «لم يبدأ» = لم يُفعّل البرنامج بعد. الطلبات المخفية والتجريبية مستبعدة.
      </p>

      <div className="table-wrap">
        <table className="t">
          <thead><tr><th>الباقة</th><th>الإجمالي</th><th>التقسيم حسب الحالة</th></tr></thead>
          <tbody>
            {products.map((p) => {
              const mine = withState.filter((o) => o.product_id === p.id);
              const users = (list: typeof mine) => new Set(list.map((o) => o.user_id)).size;
              const states = mine.some((o) => o.months > 0) || p.category === "follow" ? SUB_STATES : ONE_OFF_STATES;
              return (
                <tr key={p.id}>
                  <td>
                    <Link href={link({ pkg: p.id, state: "" })} style={{ textDecoration: "none" }}><PackageTag name={p.name} productId={p.id} /></Link>
                    <div className="small muted">{CATEGORY_LABEL[p.category]}{p.status !== "published" ? " · غير منشورة" : ""}</div>
                  </td>
                  <td className="num"><b>{users(mine)}</b></td>
                  <td>
                    <div className="row" style={{ gap: 6 }}>
                      {states.map((st) => {
                        const n = users(mine.filter((o) => o.state === st));
                        return <Link key={st} href={link({ pkg: p.id, state: st })} className={`status ${TONE[st]}`} style={{ textDecoration: "none", opacity: n ? 1 : 0.5 }}>{LABEL[st]}: {n}</Link>;
                      })}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <form className="filters" role="search">
        <div className="field"><label htmlFor="pq">بحث باسم المتدرب أو رقم الطلب</label><input id="pq" name="q" type="search" defaultValue={q} /></div>
        <div className="field"><label htmlFor="ppkg">الباقة</label>
          <select id="ppkg" name="pkg" defaultValue={sp.pkg ?? ""}><option value="">كل الباقات</option>{products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
        </div>
        <div className="field"><label htmlFor="pst">الحالة</label>
          <select id="pst" name="state" defaultValue={sp.state ?? ""}><option value="">كل الحالات</option>{[...SUB_STATES, "in_progress", "delivered"].map((st) => <option key={st} value={st}>{LABEL[st as State]}</option>)}</select>
        </div>
        <button className="btn btn-sm">عرض</button>
      </form>

      <div className="table-wrap">
        <table className="t" data-testid="trainees">
          <thead><tr><th>المتدرب</th><th>الباقة</th><th>الحالة</th><th>البدء</th><th>الانتهاء</th><th>المتبقي</th></tr></thead>
          <tbody>
            {filtered.length === 0 && <tr><td colSpan={6} className="muted">لا توجد نتائج.</td></tr>}
            {filtered.map((o) => {
              const end = o.sub_end_at ? riyadhDate(o.sub_end_at) : null;
              return (
                <tr key={o.order_no}>
                  <td>{o.contact_name}<div className="small"><Link href={`/admin/orders/${o.order_no}`}><bdi>{o.order_no}</bdi></Link></div></td>
                  <td><PackageTag name={o.product_name} productId={o.product_id} currentName={o.current_name} /></td>
                  <td><span className={`status ${TONE[o.state]}`}>{LABEL[o.state]}</span></td>
                  <td className="small">{o.sub_start_at ? fmtYMD(riyadhDate(o.sub_start_at)) : "—"}</td>
                  <td className="small">{end ? fmtYMD(end) : "—"}</td>
                  <td className="small num">{end && o.state !== "expired" && o.state !== "cancelled" ? `${daysBetween(today, end)} يوم` : "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
