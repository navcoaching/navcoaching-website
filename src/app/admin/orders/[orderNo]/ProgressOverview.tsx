import Link from "next/link";
import { withUser } from "@/lib/db";
import { fmtDate, fmtDay } from "@/lib/format";
import { loadAllLifts, loadBodyData } from "@/lib/program-data";
import { personalRecords } from "@/lib/training";
import { kcalOf } from "@/lib/nutrition";
import { addDays, riyadhDate } from "@/lib/schedule";
import { pct, type Adherence } from "@/lib/adherence";
import LineChart from "@/components/LineChart";
import { IconCheck } from "@/components/Icons";

type Week = { no: number; status: "done" | "current" | "missed" | "upcoming" };
const short = (d: string) => d.slice(5).replace("-", "/");
const num = (v: number) => Math.round(v).toLocaleString("en-US");
const signed = (v: number, unit: string) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(Math.round(v * 10) / 10)} ${unit}`;

function Kpi({ label, value, sub, tone = "", testId }: { label: string; value: string; sub: string; tone?: string; testId?: string }) {
  return (
    <div className={`kpi ${tone}`} data-testid={testId}>
      <span className="kpi-l">{label}</span>
      <b className="kpi-v">{value}</b>
      <span className="kpi-s">{sub}</span>
    </div>
  );
}

/** لوحة تطور المتدرب للمدربة: أرقام سريعة + الالتزام الأسبوعي + الوزن والقياسات والخطوات + آخر الأرقام القياسية */
export default async function ProgressOverview({ coachId, o, adherence, weeks, intakeWeight }: {
  coachId: string;
  o: { id: string; order_no: string; user_id: string };
  adherence: (Adherence & { rewarded: boolean }) | null;
  weeks: Week[];
  intakeWeight: number | null;
}) {
  const today = riyadhDate();
  const d = await withUser(coachId, async (tx) => {
    const [body, lifts, food, target, steps] = await Promise.all([
      loadBodyData(tx, o.user_id),
      loadAllLifts(tx, o.user_id),
      tx.query(`SELECT log_date::text AS day, sum(protein)::float AS protein, sum(carbs)::float AS carbs, sum(fat)::float AS fat
                  FROM food_logs WHERE order_id = $1 AND log_date BETWEEN $2::date AND $3::date GROUP BY log_date`, [o.id, addDays(today, -6), today]),
      tx.query(`SELECT kcal FROM nutrition_targets WHERE order_id = $1`, [o.id]),
      tx.query(`SELECT b.steps_goal_week AS goal, s.week_no, s.total FROM blocks b LEFT JOIN step_logs s ON s.block_id = b.id
                 WHERE b.order_id = $1 AND b.status = 'active' ORDER BY s.week_no`, [o.id]),
    ]);
    return { body, lifts, food: food.rows, target: target.rows[0]?.kcal as number | undefined, steps: steps.rows };
  });

  const w = d.body.weights;
  const startW = intakeWeight ?? w[0]?.kg ?? null;
  const lastW = w.at(-1)?.kg ?? null;
  const ms = d.body.measurements.filter((m) => m.waist != null);
  const kcalDays = d.food.map((f) => kcalOf(f));
  const kcalAvg = kcalDays.length ? kcalDays.reduce((a, b) => a + b, 0) / kcalDays.length : null;
  const reviewsDue = weeks.filter((x) => x.status === "done" || x.status === "missed");
  const reviewsDone = reviewsDue.filter((x) => x.status === "done").length;
  const lastMissed = reviewsDue.filter((x) => x.status === "missed").at(-1);
  const goal = Number(d.steps[0]?.goal ?? 0);
  const stepPts = d.steps.filter((s) => s.week_no != null).map((s) => ({ x: `الأسبوع ${s.week_no}`, y: Number(s.total) }));
  const prs = personalRecords(d.lifts).filter((p) => p.status !== "first").sort((a, b) => b.best_at.localeCompare(a.best_at)).slice(0, 5);
  const bars = adherence?.weeks.slice(-8) ?? [];

  return (
    <section id="progress" className="stack" style={{ ["--space" as string]: "14px", scrollMarginTop: 70 }} data-testid="progress-overview">
      <h2 style={{ fontSize: 20 }}>تطور المتدرب</h2>
      <div className="kpis">
        <Kpi label="الالتزام" value={adherence?.avg != null ? pct(adherence.avg) : "—"} testId="kpi-adherence"
          sub={adherence?.scored ? `متوسط ${adherence.scored} أسابيع مكتملة` : "يبدأ بعد أول أسبوع كامل"} />
        <Kpi label="أسابيع متتالية" value={String(adherence?.streak ?? 0)} sub="بالتزام 90% فأكثر" />
        <Kpi label="الوزن" value={lastW != null ? `${lastW} كغ` : "—"} testId="kpi-weight"
          tone={startW != null && lastW != null && lastW !== startW ? "good" : ""}
          sub={startW != null && lastW != null ? `${signed(lastW - startW, "كغ")} من البداية (${startW})` : "لم يسجّل وزنه بعد"} />
        <Kpi label="الخصر" value={ms.length ? `${ms.at(-1)!.waist} سم` : "—"}
          sub={ms.length > 1 ? `${signed(ms.at(-1)!.waist! - ms[0].waist!, "سم")} من أول قياس` : ms.length ? "قياس واحد فقط" : "لم يسجّل قياساته بعد"} />
        <Kpi label="السعرات (متوسط 7 أيام)" value={kcalAvg != null ? num(kcalAvg) : "—"}
          sub={kcalAvg != null ? (d.target ? `من هدف ${num(d.target)} · ${pct(kcalAvg / d.target)} · ${kcalDays.length} أيام مسجّلة` : `${kcalDays.length} أيام مسجّلة`) : "ما سجّل أكله آخر 7 أيام"} />
        <Kpi label="المراجعات" value={reviewsDue.length ? `${reviewsDone} من ${reviewsDue.length}` : "—"} tone={lastMissed ? "warn" : ""}
          sub={lastMissed ? `فاتته المراجعة ${lastMissed.no}` : reviewsDue.length ? "كلها وصلت" : "ما حان موعد أول مراجعة"} />
      </div>

      <div className="grid charts">
        <section className="card stack" style={{ ["--space" as string]: "8px" }}>
          <h3 style={{ fontSize: 17 }}>الالتزام الأسبوعي</h3>
          {bars.length === 0 ? <p className="small muted">يظهر بعد أول أسبوع كامل من الاشتراك.</p> : (
            <>
              <div className="adh-bars" style={{ gridTemplateColumns: `repeat(${bars.length}, 1fr)` }} data-testid="adherence-bars">
                {bars.map((b) => (
                  <div key={b.no} className="adh-col" title={`الأسبوع ${b.no}: تمرين ${pct(b.training)} · مراجعة ${b.review == null ? "—" : b.review ? "وصلت" : "لم تصل"}`}>
                    <span className="adh-val">{pct(b.score)}</span>
                    <div className="adh-track"><div className={`adh-fill${b.score == null ? "" : b.score >= 0.9 ? " hi" : b.score < 0.7 ? " lo" : ""}`} style={{ height: `${Math.round((b.score ?? 0) * 100)}%` }} /></div>
                    <span className="adh-wk">أ{b.no}</span>
                    <span className="adh-rv">{b.review == null ? "·" : b.review ? <IconCheck size={14} /> : "•"}</span>
                  </div>
                ))}
              </div>
              <p className="small muted" style={{ margin: 0 }}>العمود = متوسط تسجيل التمرين والمراجعة. ✓ وصلت المراجعة · • لم تصل · · ما فيه موعد.</p>
            </>
          )}
        </section>
        <section className="card stack" style={{ ["--space" as string]: "8px" }}>
          <h3 style={{ fontSize: 17 }}>الوزن</h3>
          <LineChart title="الوزن بالكيلو" unit=" كغ" series={[{ label: "الوزن", points: w.slice(-30).map((x) => ({ x: short(x.logged_on), y: x.kg, full: fmtDay(x.logged_on) })) }]} />
        </section>
        <section className="card stack" style={{ ["--space" as string]: "8px" }}>
          <h3 style={{ fontSize: 17 }}>القياسات (سم)</h3>
          <LineChart title="القياسات بالسنتيمتر" unit=" سم" series={([["waist", "الخصر", "var(--navy)"], ["hips", "الحوض", "#c77d00"], ["chest", "الصدر", "#7a4cc2"], ["thigh", "الفخذ", "var(--ok)"]] as const).map(([k, l, color]) => ({
            label: l, color, points: d.body.measurements.filter((m) => m[k] != null).map((m) => ({ x: short(m.measured_on), y: m[k] as number, full: fmtDay(m.measured_on) })),
          })).filter((s) => s.points.length)} />
        </section>
        <section className="card stack" style={{ ["--space" as string]: "8px" }}>
          <h3 style={{ fontSize: 17 }}>الخطوات الأسبوعية</h3>
          {stepPts.length ? <LineChart title="الخطوات الأسبوعية مقابل الهدف" xLabel="الأسبوع" goal={goal || null} series={[{ label: "الخطوات", points: stepPts }]} />
            : <p className="small muted">ما سجّل خطواته في البرنامج الحالي.</p>}
        </section>
      </div>

      <section className="card stack" style={{ ["--space" as string]: "10px" }}>
        <div className="row" style={{ justifyContent: "space-between" }}>
          <h3 style={{ fontSize: 17 }}>آخر الأرقام القياسية</h3>
          <Link className="small" href={`/admin/orders/${o.order_no}/program`}>كل السجلات ←</Link>
        </div>
        {prs.length === 0 ? <p className="small muted">تظهر هنا التمارين اللي زاد فيها وزنه.</p> : (
          <div className="table-wrap">
            <table className="t cards" data-testid="recent-prs">
              <thead><tr><th>التمرين</th><th className="num">أعلى وزن</th><th className="num">السابق</th><th>التاريخ</th></tr></thead>
              <tbody>
                {prs.map((p) => (
                  <tr key={p.exercise_id}><td data-label="التمرين"><bdi dir="ltr">{p.name}</bdi></td><td data-label="أعلى وزن" className="num"><b>{p.best}</b> كغ</td><td data-label="السابق" className="num">{p.previous ?? "—"}</td><td data-label="التاريخ" className="small">{fmtDate(p.best_at)}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </section>
  );
}
