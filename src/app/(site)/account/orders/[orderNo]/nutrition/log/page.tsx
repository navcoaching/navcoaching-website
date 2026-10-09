import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { fmtDate } from "@/lib/format";
import { addDays, riyadhDate } from "@/lib/schedule";
import { kcalOf, type Target } from "@/lib/nutrition";
import LineChart from "@/components/LineChart";

export const metadata: Metadata = { title: "سجل الماكروز", robots: { index: false } };

const DAYS = 30;
type Day = { log_date: string; protein: number; carbs: number; fat: number; items: number };
const n0 = (v: number) => Math.round(v).toLocaleString("en-US");
const short = (d: string) => d.slice(5).replace("-", "/");

/** سجل الماكروز: مجموع كل يوم (آخر 30 يوم) مقابل الأهداف، من نفس تسجيلات صفحة التغذية */
export default async function MacroLogPage({ params }: { params: Promise<{ orderNo: string }> }) {
  const { orderNo } = await params;
  const user = await requireUser(`/account/orders/${orderNo}/nutrition/log`);
  const today = riyadhDate();
  const from = addDays(today, -(DAYS - 1));

  const res = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, user_id FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o || o.user_id !== user.id) return null;
    const target = (await tx.query(`SELECT kcal, protein::float, carbs::float, fat::float FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0] as Target | undefined;
    const days = (await tx.query(
      `SELECT log_date::text, sum(protein)::float AS protein, sum(carbs)::float AS carbs, sum(fat)::float AS fat, count(*)::int AS items
         FROM food_logs WHERE user_id = $1 AND order_id = $2 AND log_date BETWEEN $3 AND $4
        GROUP BY log_date ORDER BY log_date`, [user.id, o.id, from, today])).rows as Day[];
    return { o, target: target ?? null, days };
  });
  if (!res) notFound();
  const { o, target, days } = res;
  const base = `/account/orders/${o.order_no}/nutrition`;
  const rows = days.map((d) => ({ ...d, kcal: kcalOf(d) }));
  const avg = (k: "kcal" | "protein" | "carbs" | "fat") => (rows.length ? rows.reduce((s, r) => s + r[k], 0) / rows.length : 0);
  const cols = [["kcal", "السعرات", ""], ["protein", "بروتين", "غ"], ["carbs", "كارب", "غ"], ["fat", "دهون", "غ"]] as const;
  const pct = (v: number, goal: number | null | undefined) => (goal ? Math.round((v / goal) * 100) : null);

  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <Link href={`/account/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / <Link href={base}>التغذية</Link> / سجل الماكروز</nav>
        <div className="row" style={{ justifyContent: "space-between", alignItems: "end" }}>
          <div>
            <h1 style={{ fontSize: "clamp(24px,4vw,32px)", margin: 0 }}>سجل الماكروز</h1>
            <p className="small muted" style={{ margin: "4px 0 0" }}>آخر {DAYS} يوم، من الأكل الذي سجّلته في صفحة التغذية.</p>
          </div>
          <Link className="btn btn-ghost btn-sm" href={base}>سجّل أكل اليوم ←</Link>
        </div>

        {rows.length === 0 ? <p className="card muted">ما فيه تسجيلات في آخر {DAYS} يوم. سجّل أكلك من صفحة التغذية ويظهر هنا مجموع كل يوم.</p> : (
          <>
            <div className="today-macros progress-stats" data-testid="macro-avg">
              {cols.map(([k, label, unit]) => (
                <div key={k}>
                  <span className="small muted">متوسط {label} اليومي</span>
                  <b className="num">{n0(avg(k))}{unit && ` ${unit}`}</b>
                  {target?.[k] != null && <span className="small muted">الهدف {n0(target[k]!)}{unit && ` ${unit}`} · {pct(avg(k), target[k])}٪</span>}
                </div>
              ))}
            </div>
            <p className="small muted" style={{ margin: 0 }}>المتوسط من {rows.length} يوم مسجّل.</p>

            <div className="grid g2">
              <section className="card stack">
                <h2 style={{ fontSize: 17 }}>السعرات اليومية</h2>
                <LineChart title="السعرات اليومية مقابل الهدف" goal={target?.kcal ?? null} series={[{ label: "السعرات", points: rows.map((r) => ({ x: short(r.log_date), y: Math.round(r.kcal) })) }]} />
              </section>
              <section className="card stack">
                <h2 style={{ fontSize: 17 }}>البروتين اليومي</h2>
                <LineChart title="البروتين اليومي مقابل الهدف" unit=" غ" goal={target?.protein ?? null} series={[{ label: "البروتين", points: rows.map((r) => ({ x: short(r.log_date), y: Math.round(r.protein) })) }]} />
              </section>
            </div>
            {target && <p className="small muted" style={{ margin: 0 }}>الخط المتقطع الأخضر = هدفك.</p>}

            <section className="card stack">
              <h2 style={{ fontSize: 17 }}>كل يوم</h2>
              <div className="table-wrap">
                <table className="t" data-testid="macro-log">
                  <thead><tr><th>اليوم</th>{cols.map(([k, label]) => <th key={k} className="num">{label}</th>)}<th className="num">أكلات</th></tr></thead>
                  <tbody>
                    {[...rows].reverse().map((r) => (
                      <tr key={r.log_date}>
                        <td><Link href={`${base}?date=${r.log_date}`}>{r.log_date === today ? "اليوم" : fmtDate(r.log_date)}</Link></td>
                        {cols.map(([k]) => {
                          const p = pct(r[k], target?.[k]);
                          return <td key={k} className="num">{n0(r[k])}{p != null && <div className={`small ${p >= 90 && p <= 110 ? "ok-text" : "muted"}`}>{p}٪</div>}</td>;
                        })}
                        <td className="num">{r.items}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {target && <p className="small muted" style={{ margin: 0 }}>النسبة = ما أكلته ÷ هدفك. بالأخضر إذا كانت بين 90٪ و110٪.</p>}
            </section>
          </>
        )}
      </div>
    </section>
  );
}
