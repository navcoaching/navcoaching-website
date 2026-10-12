/** رسم خطي بسيط SVG (بدون مكتبات). يعرض من اليسار لليمين زمنياً مع تسميات واضحة.
 *  الخطوط داخل SVG يتمدد بعرض البطاقة، والتسميات HTML بحجم ثابت، فالنص ما يكبر ولا يصغر مع عرض الشاشة. */
export type Series = { label: string; color?: string; points: { x: string; y: number }[] };

export default function LineChart({ series, goal, unit = "", height = 200, title }: {
  series: Series[]; goal?: number | null; unit?: string; height?: number; title: string;
}) {
  const xs = [...new Set(series.flatMap((s) => s.points.map((p) => p.x)))];
  const ys = series.flatMap((s) => s.points.map((p) => p.y)).concat(goal ? [goal] : []);
  if (xs.length === 0 || ys.length === 0) return <p className="small muted">لا توجد بيانات بعد.</p>;
  const colors = ["var(--navy)", "var(--cyan)", "#c77d00", "#7a4cc2"];
  const fmtVal = (v: number) => (Number.isInteger(v) ? v.toLocaleString("en-US") : String(v));
  // نقطة واحدة ما تكفي لرسم: تُعرض القيمة نصاً
  if (xs.length < 2) {
    return (
      <div className="chart-empty">
        <p className="small muted">يظهر الرسم بعد تسجيلين على الأقل.</p>
        <p>{series.map((s) => s.points[0] && <span key={s.label}><b dir="ltr">{fmtVal(s.points[0].y)}{unit}</b> {series.length > 1 ? s.label : ""} <span className="small muted">({s.points[0].x})</span> </span>)}</p>
      </div>
    );
  }
  const W = 100, H = 100;
  let min = Math.min(...ys), max = Math.max(...ys);
  const nonNeg = min >= 0;
  if (min === max) { min -= 1; max += 1; }
  const pad = (max - min) * 0.1; min -= pad; max += pad;
  if (nonNeg) min = Math.max(0, min); // الأعداد والمبالغ ما تنزل تحت الصفر
  const x = (i: number) => (i * W) / (xs.length - 1);
  const y = (v: number) => (1 - (v - min) / (max - min)) * H;
  const ticks = [0, 0.5, 1].map((t) => min + t * (max - min));
  const fmt = (v: number) => (Math.abs(max - min) > 50 ? Math.round(v).toLocaleString("en-US") : v.toFixed(1));
  const every = Math.ceil(xs.length / 7);
  const plotH = Math.round(height * 0.7);
  return (
    <figure className="chart" dir="ltr">
      <div className="chart-plot" style={{ height: plotH }}>
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={title}>
          {ticks.map((t) => <line key={t} x1={0} x2={W} y1={y(t)} y2={y(t)} stroke="var(--line)" vectorEffect="non-scaling-stroke" />)}
          {goal != null && <line x1={0} x2={W} y1={y(goal)} y2={y(goal)} stroke="var(--ok)" strokeWidth="2" strokeDasharray="6 4" vectorEffect="non-scaling-stroke" />}
          {series.map((s, si) => {
            const pts = s.points.map((p) => [x(xs.indexOf(p.x)), y(p.y)] as const);
            const c = s.color ?? colors[si % colors.length];
            return (
              <g key={s.label}>
                {pts.length > 1 && <polyline fill="none" stroke={c} strokeWidth="2.5" strokeLinejoin="round" points={pts.map((p) => p.join(",")).join(" ")} vectorEffect="non-scaling-stroke" />}
                {/* خط بطول صفر بنهاية دائرية = نقطة دائرية ما تتشوه مع التمدد */}
                {pts.map(([px, py], i) => <line key={i} x1={px} x2={px} y1={py} y2={py} stroke={c} strokeWidth="8" strokeLinecap="round" vectorEffect="non-scaling-stroke"><title>{`${s.points[i].x}: ${s.points[i].y}${unit}`}</title></line>)}
              </g>
            );
          })}
        </svg>
        {ticks.map((t) => <span key={t} className="chart-y" style={{ top: `${y(t)}%` }}>{fmt(t)}</span>)}
        {xs.map((lbl, i) => (i === xs.length - 1 || (i % every === 0 && xs.length - 1 - i >= Math.max(1, every * 0.75))) && (
          <span key={lbl} className="chart-x" style={{ left: `${x(i)}%` }}>{lbl}</span>
        ))}
      </div>
      {(series.length > 1 || goal != null) && (
        <figcaption className="chart-legend" dir="rtl">
          {series.map((s, si) => <span key={s.label}><i style={{ background: s.color ?? colors[si % colors.length] }} />{s.label}</span>)}
          {goal != null && <span><i className="goal" />الهدف</span>}
        </figcaption>
      )}
    </figure>
  );
}
