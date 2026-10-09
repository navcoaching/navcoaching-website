import { remaining, type Target } from "@/lib/nutrition";

const n = (v: number | null) => (v == null ? "—" : Math.round(v).toLocaleString("en-US"));

/** ملخص اليوم بأسلوب تطبيقات التغذية: حلقة «المتبقي من السعرات» والماكروز الثلاثة بأشرطة صغيرة */
export default function DaySummary({ target, total }: { target: Target; total: { kcal: number; protein: number; carbs: number; fat: number } }) {
  const r = remaining(target, total);
  const R = 52, C = 2 * Math.PI * R;
  const pct = r.kcal.pct == null ? 0 : Math.min(1, r.kcal.pct);
  const over = r.kcal.left != null && r.kcal.left < 0;
  return (
    <section className="card day-summary" aria-label="ملخص اليوم" data-testid="macro-summary">
      <div className="ring-wrap">
        <svg viewBox="0 0 120 120" className="ring" role="img" aria-label={r.kcal.left == null ? "لم يُحدَّد هدف السعرات" : over ? `تجاوزت ${n(-r.kcal.left)} سعرة` : `المتبقي ${n(r.kcal.left)} سعرة`}>
          <circle cx="60" cy="60" r={R} className="ring-bg" />
          <circle cx="60" cy="60" r={R} className={`ring-fg${over ? " over" : ""}`} strokeDasharray={`${C * pct} ${C}`} transform="rotate(-90 60 60)" />
        </svg>
        <div className="ring-text">
          <b className="num">{r.kcal.left == null ? n(total.kcal) : n(Math.abs(r.kcal.left))}</b>
          <span className="small muted">{r.kcal.left == null ? "سعرة اليوم" : over ? "تجاوز" : "متبقي"}</span>
        </div>
      </div>
      <dl className="day-eq">
        <div><dt>الهدف</dt><dd className="num">{n(r.kcal.goal)}</dd></div>
        <div><dt>الأكل</dt><dd className="num">{n(total.kcal)}</dd></div>
      </dl>
      <div className="day-macros">
        {([["protein", "بروتين"], ["carbs", "كارب"], ["fat", "دهون"]] as const).map(([k, label]) => {
          const x = r[k];
          const p = x.pct == null ? 0 : Math.min(1, x.pct);
          return (
            <div key={k} className={`day-macro m-${k}`}>
              <span className="small"><b>{label}</b></span>
              <div className={`bar${x.left != null && x.left < 0 ? " over" : ""}`} role="progressbar" aria-valuenow={Math.round((x.pct ?? 0) * 100)} aria-valuemin={0} aria-valuemax={100} aria-label={label}><i style={{ width: `${p * 100}%` }} /></div>
              <span className="small num"><bdi>{n(x.got)}</bdi>{x.goal != null ? ` / ${n(x.goal)}` : ""} غ</span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
