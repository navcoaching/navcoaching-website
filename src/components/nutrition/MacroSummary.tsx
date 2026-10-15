import { remaining, type Target } from "@/lib/nutrition";

const n = (v: number | null) => (v == null ? "—" : Math.round(v).toLocaleString("en-US"));
const ROWS = [["kcal", "السعرات", ""], ["protein", "البروتين", "غ"], ["carbs", "الكارب", "غ"], ["fat", "الدهون", "غ"]] as const;

/** الهدف ← الحالي ← المتبقي مع شريط الاكتمال (مثل «مؤشرات اكتمال الأهداف» في Macro Log) */
export default function MacroSummary({ target, total, title = "ملخص اليوم" }: {
  target: Target; total: { kcal: number; protein: number; carbs: number; fat: number }; title?: string;
}) {
  const r = remaining(target, total);
  return (
    <section className="card stack macro-summary" style={{ ["--space" as string]: "10px" }} aria-label={title} data-testid="macro-summary">
      <h2 style={{ fontSize: 17 }}>{title}</h2>
      {ROWS.map(([k, label, unit]) => {
        const x = r[k];
        const pct = x.pct == null ? null : Math.min(1, x.pct);
        const over = x.left != null && x.left < 0;
        return (
          <div key={k} className="macro-row">
            <div className="macro-head">
              <b>{label}</b>
              <span className="small"><bdi>{n(x.got)}</bdi>{x.goal != null && <> / <bdi>{n(x.goal)}</bdi></>} {unit}</span>
            </div>
            {pct != null && <div className={`bar ${over ? "over" : ""}`} role="progressbar" aria-valuenow={Math.round((x.pct ?? 0) * 100)} aria-valuemin={0} aria-valuemax={100} aria-label={label}><i style={{ width: `${pct * 100}%` }} /></div>}
            {x.left != null && <span className={`small ${over ? "err-text" : "muted"}`}>{over ? `تجاوزت بـ ${n(-x.left)} ${unit}` : `المتبقي ${n(x.left)} ${unit}`}</span>}
          </div>
        );
      })}
    </section>
  );
}
