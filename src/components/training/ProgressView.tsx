import LineChart from "@/components/LineChart";
import { fmtDate, fmtDay } from "@/lib/format";
import { personalRecords, weeklyAverages, weeklySummary, type LiftLog } from "@/lib/training";
import type { BlockData, BodyData } from "@/lib/program-data";
import { painTone } from "@/lib/pain";

const pct = (v: number) => `${Math.round(v * 100)}٪`;
const num = (v: number) => Math.round(v).toLocaleString("en-US");
const short = (d: string) => d.slice(5).replace("-", "/");

/** الملخص الأسبوعي + الرسوم + الأرقام القياسية — نفس العرض للمتدرب والمدربة */
export default function ProgressView({ data, body, lifts }: {
  data: BlockData | null; body: BodyData; lifts: LiftLog[];
}) {
  const items = data ? data.days.flatMap((d) => d.items) : [];
  const summary = data ? weeklySummary(items, data.logs, data.block.weeks) : [];
  const avgW = data ? weeklyAverages(body.weights.map((w) => ({ date: w.logged_on, value: w.kg })), data.block.start_date) : [];
  const steps = new Map(data?.steps.map((s) => [s.week_no, s.total]) ?? []);
  // مقياس الألم (إن وُجد في البرنامج): متوسط وأعلى قيمة لكل أسبوع. اسم واحد إذا كل التمارين بنفس المنطقة
  const painItems = new Set(items.filter((i) => i.pain_label).map((i) => i.id));
  const painNames = [...new Set(items.map((i) => i.pain_label).filter(Boolean))];
  const painWeek = (w: number) => {
    const v = (data?.logs ?? []).filter((l) => l.week_no === w && painItems.has(l.block_item_id) && l.pain != null).map((l) => l.pain!);
    return v.length ? { avg: v.reduce((a, b) => a + b, 0) / v.length, max: Math.max(...v) } : null;
  };
  const prs = personalRecords(lifts);
  const recentW = body.weights.slice(-24);
  const M = [["waist", "الخصر"], ["hips", "الحوض"], ["chest", "الصدر"], ["thigh", "الفخذ"]] as const;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      {data && (
        <section className="card stack" aria-labelledby="ws-h">
          <h2 id="ws-h" style={{ fontSize: 18 }}>الملخص الأسبوعي — {data.block.name}</h2>
          <div className="table-wrap">
            <table className="t sticky-first" data-testid="weekly-summary">
              <thead><tr><th>المؤشر</th>{summary.map((s) => <th key={s.week} className="num">الأسبوع {s.week}</th>)}</tr></thead>
              <tbody>
                <tr><th scope="row">الالتزام (تمارين مسجّلة)</th>{summary.map((s) => <td key={s.week} className="num">{s.logged ? pct(s.adherence) : "—"}</td>)}</tr>
                <tr><th scope="row">الحجم التدريبي (VLU)</th>{summary.map((s) => <td key={s.week} className="num">{s.logged ? num(s.vlu) : "—"}</td>)}</tr>
                <tr><th scope="row">التغيّر عن الأسبوع السابق</th>{summary.map((s) => <td key={s.week} className="num">{s.change == null ? "—" : <bdi dir="ltr">{`${s.change > 0 ? "+" : ""}${Math.round(s.change * 100)}%`}</bdi>}</td>)}</tr>
                {painItems.size > 0 && (
                  <tr data-testid="pain-row"><th scope="row">{painNames.length === 1 ? painNames[0] : "الألم"} (المتوسط · الأعلى)</th>{summary.map((s) => {
                    const p = painWeek(s.week);
                    return <td key={s.week} className="num">{p ? <span className={`pain-chip ${painTone(p.max)}`}><bdi dir="ltr">{p.avg.toFixed(1)} · {p.max}</bdi></span> : "—"}</td>;
                  })}</tr>
                )}
                <tr><th scope="row">متوسط الوزن (كغ)</th>{summary.map((s) => { const a = avgW.find((w) => w.week === s.week); return <td key={s.week} className="num">{a ? a.avg.toFixed(1) : "—"}</td>; })}</tr>
                <tr><th scope="row">الخطوات / الهدف {num(data.block.steps_goal_week)}</th>{summary.map((s) => { const t = steps.get(s.week); return <td key={s.week} className="num">{t == null ? "—" : <>{num(t)}{data.block.steps_goal_week > 0 && <div className="small muted">{pct(t / data.block.steps_goal_week)}</div>}</>}</td>; })}</tr>
              </tbody>
            </table>
          </div>
          <p className="small muted">VLU = مجموع التكرارات × الوزن × (1 − RIR × 0.05). الالتزام = التمارين التي سُجّل لها وزن ÷ كل تمارين البرنامج.</p>
        </section>
      )}

      <div className="grid g2">
        <section className="card stack" aria-labelledby="wt-h">
          <h2 id="wt-h" style={{ fontSize: 17 }}>الوزن</h2>
          <LineChart title="الوزن بالكيلو" unit=" كغ" series={[{ label: "الوزن", points: recentW.map((w) => ({ x: short(w.logged_on), y: w.kg, full: fmtDay(w.logged_on) })) }]} />
          {avgW.length > 1 && <p className="small muted">متوسط أول أسبوع {avgW[0].avg.toFixed(1)} ← آخر أسبوع {avgW[avgW.length - 1].avg.toFixed(1)} كغ</p>}
        </section>
        <section className="card stack" aria-labelledby="ms-h">
          <h2 id="ms-h" style={{ fontSize: 17 }}>القياسات (سم)</h2>
          <LineChart title="القياسات بالسنتيمتر" unit=" سم" series={M.map(([k, l]) => ({
            label: l, points: body.measurements.filter((m) => m[k] != null).map((m) => ({ x: short(m.measured_on), y: m[k] as number, full: fmtDay(m.measured_on) })),
          })).filter((s) => s.points.length)} />
        </section>
      </div>

      {data && data.block.steps_goal_week > 0 && (
        <section className="card stack" aria-labelledby="st-h">
          <h2 id="st-h" style={{ fontSize: 17 }}>الخطوات الأسبوعية</h2>
          <LineChart title="الخطوات الأسبوعية مقابل الهدف" xLabel="الأسبوع" goal={data.block.steps_goal_week}
            series={[{ label: "الخطوات", points: data.steps.map((s) => ({ x: `الأسبوع ${s.week_no}`, y: s.total })) }]} />
        </section>
      )}

      <section className="card stack" aria-labelledby="pr-h">
        <h2 id="pr-h" style={{ fontSize: 18 }}>الأرقام القياسية</h2>
        {prs.length === 0 ? <p className="small muted">تظهر هنا أعلى أوزانك لكل تمرين بعد ما تسجّل تمارينك.</p> : (
          <div className="table-wrap">
            <table className="t cards" data-testid="prs">
              <thead><tr><th>التمرين</th><th className="num">أعلى وزن</th><th className="num">1RM تقديري</th><th className="num">السابق</th><th>الحالة</th><th>التاريخ</th></tr></thead>
              <tbody>
                {prs.map((p) => (
                  <tr key={p.exercise_id}>
                    <td data-label="التمرين"><bdi dir="ltr">{p.name}</bdi></td>
                    <td data-label="أعلى وزن" className="num"><b>{p.best}</b> كغ</td>
                    <td data-label="1RM تقديري" className="num">{p.oneRm > 0 ? `${p.oneRm} كغ` : "—"}</td>
                    <td data-label="السابق" className="num">{p.previous ?? "—"}</td>
                    <td data-label="الحالة">{p.status === "new" ? <span className="status ok">رقم قياسي جديد</span> : p.status === "first" ? <span className="status muted">أول تسجيل</span> : <span className="status muted">ثابت</span>}</td>
                    <td data-label="التاريخ" className="small">{fmtDate(p.best_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {prs.length > 0 && <p className="small muted" style={{ margin: 0 }}>1RM تقديري = أعلى وزن ممكن لتكرار واحد، محسوب من أفضل جولة بمعادلة Epley: الوزن × (1 + التكرارات ÷ 30). أدق مع 10 تكرارات أو أقل، ولا يلزم اختباره فعلياً.</p>}
      </section>
    </div>
  );
}
