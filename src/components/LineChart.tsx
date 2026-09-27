/** رسم خطي بسيط SVG (بدون مكتبات). يعرض من اليسار لليمين زمنياً مع تسميات واضحة. */
export type Series = { label: string; color?: string; points: { x: string; y: number }[] };

export default function LineChart({ series, goal, unit = "", height = 200, title }: {
  series: Series[]; goal?: number | null; unit?: string; height?: number; title: string;
}) {
  const xs = [...new Set(series.flatMap((s) => s.points.map((p) => p.x)))];
  const ys = series.flatMap((s) => s.points.map((p) => p.y)).concat(goal ? [goal] : []);
  if (xs.length === 0 || ys.length === 0) return <p className="small muted">لا توجد بيانات بعد.</p>;
  const W = 400, H = Math.round(height * 0.75), L = 44, R = 10, T = 12, B = 30;
  let min = Math.min(...ys), max = Math.max(...ys);
  if (min === max) { min -= 1; max += 1; }
  const pad = (max - min) * 0.1; min -= pad; max += pad;
  const x = (i: number) => (xs.length === 1 ? L + (W - L - R) / 2 : L + (i * (W - L - R)) / (xs.length - 1));
  const y = (v: number) => T + (1 - (v - min) / (max - min)) * (H - T - B);
  const ticks = [0, 0.5, 1].map((t) => min + t * (max - min));
  const colors = ["var(--navy)", "var(--cyan)", "#c77d00", "#7a4cc2"];
  const fmt = (v: number) => (Math.abs(max - min) > 50 ? Math.round(v).toLocaleString("en-US") : v.toFixed(1));
  const every = Math.ceil(xs.length / 8);
  return (
    <figure className="chart" dir="ltr">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} stroke="var(--line)" />
            <text x={L - 6} y={y(t) + 4} textAnchor="end" fontSize="13" fill="var(--muted)">{fmt(t)}</text>
          </g>
        ))}
        {goal != null && <line x1={L} x2={W - R} y1={y(goal)} y2={y(goal)} stroke="var(--ok)" strokeDasharray="6 4" />}
        {xs.map((lbl, i) => (i % every === 0 || i === xs.length - 1) && (
          <text key={lbl} x={x(i)} y={H - 10} textAnchor="middle" fontSize="13" fill="var(--muted)">{lbl}</text>
        ))}
        {series.map((s, si) => {
          const pts = s.points.map((p) => [x(xs.indexOf(p.x)), y(p.y)] as const);
          const c = s.color ?? colors[si % colors.length];
          return (
            <g key={s.label}>
              {pts.length > 1 && <polyline fill="none" stroke={c} strokeWidth="2.5" points={pts.map((p) => p.join(",")).join(" ")} vectorEffect="non-scaling-stroke" />}
              {pts.map(([px, py], i) => <circle key={i} cx={px} cy={py} r="3.5" fill={c}><title>{`${s.points[i].x}: ${s.points[i].y}${unit}`}</title></circle>)}
            </g>
          );
        })}
      </svg>
      {(series.length > 1 || goal != null) && (
        <figcaption className="chart-legend" dir="rtl">
          {series.map((s, si) => <span key={s.label}><i style={{ background: s.color ?? colors[si % colors.length] }} />{s.label}</span>)}
          {goal != null && <span><i className="goal" />الهدف</span>}
        </figcaption>
      )}
    </figure>
  );
}
