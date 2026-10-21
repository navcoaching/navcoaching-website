import Link from "next/link";
import LineChart from "@/components/LineChart";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { riyadhDate } from "@/lib/schedule";
import { goalFor, loadGoals, loadMonths, monthName, type MonthRow } from "@/lib/monthly-stats";

export const metadata = { title: "أرشيف الأرقام" };

const n = (v: number, unit = "") => `${v.toLocaleString("en-US")}${unit}`;
const sum = (rows: MonthRow[], k: "orders" | "members" | "revenue") => rows.reduce((a, r) => a + r[k], 0);
const change = (cur: number, prev: number) => (prev === 0 ? (cur === 0 ? "—" : "جديد") : `${cur >= prev ? "↑" : "↓"} ${Math.abs(Math.round(((cur - prev) / prev) * 100))}%`);

export default async function StatsArchive({ searchParams }: { searchParams: Promise<{ year?: string }> }) {
  const coach = await requireCoach();
  const nowYm = riyadhDate().slice(0, 7), thisYear = +nowYm.slice(0, 4);
  const { year: y } = await searchParams;
  const { first, rows, goals } = await withUser(coach.id, async (tx) => {
    // أول سنة فيها بيانات، عشان أزرار السنوات
    const firstYear = Number((await tx.query(
      `SELECT extract(year FROM least((SELECT min(created_at) FROM orders WHERE NOT is_demo), (SELECT min("createdAt") FROM "user" WHERE role = 'client'), now()) AT TIME ZONE 'Asia/Riyadh')::int AS y`)).rows[0].y);
    const year = Math.min(thisYear, Math.max(firstYear, Number(y) || thisYear));
    // السنة المختارة والسنة اللي قبلها (للمقارنة) في استعلام واحد، لين الشهر الحالي فقط
    const end = year === thisYear ? nowYm : `${year}-12`;
    return { first: firstYear, rows: await loadMonths(tx, `${year - 1}-01`, end), goals: await loadGoals(tx) };
  });
  const year = +rows.at(-1)!.ym.slice(0, 4);
  const cur = rows.filter((r) => r.ym.startsWith(`${year}-`)).reverse(); // الأحدث أولاً
  const prev = new Map(rows.filter((r) => r.ym.startsWith(`${year - 1}-`)).map((r) => [r.ym.slice(5), r]));
  const prevSame = cur.map((r) => prev.get(r.ym.slice(5))).filter((r): r is MonthRow => Boolean(r)); // نفس الأشهر من السنة الماضية
  const years = Array.from({ length: thisYear - first + 1 }, (_, i) => thisYear - i);

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>أرشيف الأرقام</h1>
      <p className="muted" style={{ margin: 0 }}>أرقام كل شهر محفوظة هنا للرجوع لها، ومقارنتها بنفس الشهر من السنة الماضية. الصفحة الرئيسية تعرض الشهر الحالي فقط.</p>
      {years.length > 1 && (
        <nav className="pill-nav" aria-label="السنة">
          {years.map((v) => <Link key={v} href={`/admin/stats?year=${v}`} aria-current={v === year ? "true" : undefined}>{v}</Link>)}
        </nav>
      )}
      <div className="grid g3" data-testid="year-totals">
        {([["members", "الأعضاء الجدد", ""], ["revenue", "المبالغ المدفوعة", " ريال"], ["orders", "الطلبات", ""]] as const).map(([k, title, unit]) => (
          <div key={k} className="card stack" style={{ ["--space" as string]: "6px" }}>
            <span className="muted">{title} — {year}</span>
            <b className="num" style={{ fontSize: 26 }}>{n(sum(cur, k), unit)}</b>
            <span className="small muted">نفس الفترة {year - 1}: {n(sum(prevSame, k), unit)} · {change(sum(cur, k), sum(prevSame, k))}</span>
          </div>
        ))}
      </div>
      <section className="card" aria-labelledby="months-h">
        <h2 id="months-h" style={{ fontSize: 18, marginBottom: 12 }}>الأشهر</h2>
        <div className="table-wrap">
          <table className="t stats-table" data-testid="stats-table">
            <thead><tr><th>الشهر</th><th>الأعضاء الجدد</th><th>هدف الأعضاء</th><th>المبالغ المدفوعة</th><th>هدف المبالغ</th><th>الطلبات</th><th>المبالغ {year - 1}</th></tr></thead>
            <tbody>
              {cur.map((r) => {
                const g = goalFor(goals, r.ym), p = prev.get(r.ym.slice(5));
                return (
                  <tr key={r.ym}>
                    <td>{monthName(r.ym)}{r.ym === nowYm && <span className="small muted"> (الحالي)</span>}</td>
                    <td className={`num ${g.members && r.members >= g.members ? "goal-hit" : ""}`}>{n(r.members)}</td>
                    <td className="num">{g.members != null ? n(g.members) : "—"}</td>
                    <td className={`num ${g.revenue && r.revenue >= g.revenue ? "goal-hit" : ""}`}>{n(r.revenue)}</td>
                    <td className="num">{g.revenue != null ? n(g.revenue) : "—"}</td>
                    <td className="num">{n(r.orders)}</td>
                    <td className="num muted">{p ? n(p.revenue) : "—"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <p className="small muted" style={{ marginTop: 10 }}>المبالغ بالريال. الرقم الأخضر يعني تحقق هدف الشهر.</p>
      </section>
      {cur.length > 1 && (
        <div className="grid g2">
          {([["members", "الأعضاء الجدد", "", "var(--cyan)"], ["revenue", "المبالغ المدفوعة", " ريال", "#c77d00"]] as const).map(([k, title, unit, color]) => (
            <div key={k} className="card">
              <h2 style={{ fontSize: 16, marginBottom: 8 }}>{title}: {year} مقابل {year - 1}</h2>
              <LineChart title={`${title} ${year}`} unit={unit} height={170} xLabel="الشهر" series={[
                { label: String(year), color, points: [...cur].reverse().map((r) => ({ x: r.ym.slice(5), y: r[k] })) },
                ...(prevSame.length ? [{ label: String(year - 1), color: "var(--muted)", points: [...cur].reverse().map((r) => ({ x: r.ym.slice(5), y: prev.get(r.ym.slice(5))?.[k] ?? 0 })) }] : []),
              ]} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
