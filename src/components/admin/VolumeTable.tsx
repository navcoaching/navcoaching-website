import ActionForm from "@/components/admin/ActionForm";
import { saveVolumeLimitsAction } from "@/app/actions/training";
import { NOT_MUSCLES, muscleLabel, muscleOrder, volumeStatus, weeklyVolume, type Limits, type VolumeItem } from "@/lib/volume";

const fmt = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(1));

/** جدول الجولات الأسبوعية لكل عضلة (للمدربة فقط): الأساسية جولة، والثانوية نصف جولة، مع حدود تضعها المدربة */
export default function VolumeTable({ items, weeks, limits, muscles }: { items: VolumeItem[]; weeks: number; limits: Limits; muscles: string[] }) {
  const vol = weeklyVolume(items, weeks);
  const order = muscleOrder(vol, limits);
  const all = muscles.filter((m) => !NOT_MUSCLES.some((x) => m.startsWith(x)));
  return (
    <details className="card stack volume" data-testid="volume" open>
      <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>📊 الجولات الأسبوعية لكل عضلة <span className="small muted">(لكِ فقط)</span></summary>
      {order.length === 0 ? <p className="small muted" style={{ margin: 0 }}>أضيفي تمارين وجولات ليظهر الحساب.</p> : (
        <div className="table-wrap">
          <table className="small">
            <thead><tr><th scope="col">العضلة</th>{vol.map((_, w) => <th key={w} scope="col">أ{w + 1}</th>)}<th scope="col">الحد</th></tr></thead>
            <tbody>
              {order.map((m) => {
                const l = limits[m];
                return (
                  <tr key={m}>
                    <th scope="row"><bdi dir="ltr">{muscleLabel(m)}</bdi></th>
                    {vol.map((v, w) => {
                      const n = v.get(m) ?? 0, st = volumeStatus(n, l);
                      return <td key={w} className={`num vol-${st}`} title={st === "low" ? "أقل من الحد" : st === "high" ? "أعلى من الحد" : undefined}>{fmt(n)}</td>;
                    })}
                    <td className="num muted"><bdi dir="ltr">{l && (l.min != null || l.max != null) ? `${l.min ?? "—"}–${l.max ?? "—"}` : "—"}</bdi></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <p className="small muted" style={{ margin: 0 }}>العضلة الأساسية للتمرين = جولة، وكل عضلة ثانوية = نصف جولة. الإطالات والوظيفية والانفجارية وكروس فت ما تنحسب. <span className="vol-low">أحمر</span> أقل من الحد، <span className="vol-high">برتقالي</span> أعلى منه.</p>
      <details>
        <summary className="small" style={{ cursor: "pointer", minHeight: 40 }}>تعديل الحدود لكل عضلة (تنطبق على كل البرامج)</summary>
        <ActionForm action={saveVolumeLimitsAction} submit="حفظ الحدود" submitClass="btn btn-ghost btn-sm">
          <div className="vol-limits">
            {all.map((m) => (
              <div key={m} className="vol-limit">
                <input type="hidden" name="muscle" value={m} />
                <span className="small"><bdi dir="ltr">{muscleLabel(m)}</bdi></span>
                <input name="min" type="number" inputMode="numeric" min={0} max={60} step={0.5} aria-label={`الحد الأدنى — ${muscleLabel(m)}`} placeholder="أدنى" defaultValue={limits[m]?.min ?? ""}/>
                <input name="max" type="number" inputMode="numeric" min={0} max={60} step={0.5} aria-label={`الحد الأعلى — ${muscleLabel(m)}`} placeholder="أعلى" defaultValue={limits[m]?.max ?? ""} />
              </div>
            ))}
          </div>
        </ActionForm>
      </details>
    </details>
  );
}
