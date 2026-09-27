import { effective, formatReps, planLabel } from "@/lib/training";
import type { BlockData } from "@/lib/program-data";

/** جدول يوم بنفس شكل الشيت: التمارين صفوف والأسابيع أعمدة (المستهدف ثم المسجّل) */
export default function DayLogTable({ data, dayId }: { data: BlockData; dayId: string }) {
  const day = data.days.find((d) => d.id === dayId)!;
  const weeks = Array.from({ length: data.block.weeks }, (_, i) => i + 1);
  const log = (item: string, w: number) => data.logs.find((l) => l.block_item_id === item && l.week_no === w);
  const rating = (w: number) => data.ratings.find((r) => r.block_day_id === dayId && r.week_no === w)?.rating;
  return (
    <div className="table-wrap">
      <table className="t log-table">
        <thead><tr><th>التمرين</th>{weeks.map((w) => <th key={w}>الأسبوع {w}</th>)}</tr></thead>
        <tbody>
          {day.items.map((it) => (
            <tr key={it.id}>
              <th scope="row"><bdi dir="ltr">{data.exercises.get(it.exercise_id)?.name ?? "—"}</bdi></th>
              {weeks.map((w) => {
                const l = log(it.id, w);
                const e = l ? effective(l, it.plan[w - 1]) : null;
                return (
                  <td key={w}>
                    <div className="small muted">{planLabel(it.plan[w - 1])}</div>
                    {l && e ? (
                      <div>
                        <b>{l.weight}</b> كغ · <bdi dir="ltr">{formatReps(e.reps)}</bdi>{e.rir != null && <> · RIR {e.rir}</>}
                        <div className="small muted">VLU {Math.round(e.vlu).toLocaleString("en-US")}{l.exercise_id !== it.exercise_id && <> · <bdi dir="ltr">{data.exercises.get(l.exercise_id)?.name}</bdi></>}</div>
                      </div>
                    ) : <span className="muted">—</span>}
                  </td>
                );
              })}
            </tr>
          ))}
          <tr><th scope="row">تقييم اليوم (1–5)</th>{weeks.map((w) => <td key={w} className="num">{rating(w) ?? "—"}</td>)}</tr>
        </tbody>
      </table>
    </div>
  );
}
