import ActionForm from "@/components/admin/ActionForm";
import ExercisePicker, { ExercisesProvider, type PickerExercise } from "@/components/admin/ExercisePicker";
import { addDayAction, addItemAction, deleteDayAction, deleteItemAction, saveDayAction, saveItemAction } from "@/app/actions/training";
import { formatReps, planLabel, type PlanWeek } from "@/lib/training";
import { muscleAr } from "@/lib/exercises";

export type EditorItem = { id: string; exercise_id?: string; name: string; plan: PlanWeek[]; note: string | null; coach_name?: string | null; logs?: number };
export type EditorDay = { id: string; day_no: number; title: string; items: EditorItem[] };
export type ExOption = PickerExercise;

/** محرر البرنامج: نفس الواجهة للقالب ولبلوك المتدرب (kind) */
export default function ProgramEditor({ kind, ownerId, weeks, days, exercises }: {
  kind: "template" | "block"; ownerId: string; weeks: number; days: EditorDay[]; exercises: ExOption[];
}) {
  const hidden = (extra: Record<string, string>) => (
    <><input type="hidden" name="kind" value={kind} />{Object.entries(extra).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}</>
  );
  return (
    <ExercisesProvider exercises={exercises}>
    <div className="stack" style={{ ["--space" as string]: "16px" }}>
      <datalist id="ex-options">
        {exercises.map((e) => <option key={e.name} value={e.name}>{muscleAr(e.primary_muscle)}{e.equipment ? ` · ${e.equipment}` : ""}</option>)}
      </datalist>
      {days.map((d) => (
        <section key={d.id} className="card program-day" data-testid={`day-${d.day_no}`}>
          <details className="day-fold">
          <summary className="day-toggle" data-testid={`fold-${d.day_no}`}>
            <b>اليوم {d.day_no}: <bdi dir="ltr">{d.title}</bdi></b>
            <span className="small muted">{d.items.length} تمارين</span>
            <span className="btn btn-ghost btn-sm day-toggle-btn" aria-hidden="true"><span className="when-open">طيّ اليوم ▴</span><span className="when-closed">فتح اليوم ▾</span></span>
          </summary>
          <div className="stack" style={{ ["--space" as string]: "12px", marginTop: 12 }}>
          <div className="row" style={{ justifyContent: "space-between", alignItems: "end", gap: 10 }}>
            <ActionForm action={saveDayAction} className="form inline-form" submit="حفظ العنوان" submitClass="btn btn-ghost btn-sm">
              {hidden({ day: d.id })}
              <div className="field"><label htmlFor={`dt-${d.id}`}>اليوم {d.day_no}</label>
                <input id={`dt-${d.id}`} name="title" type="text" required maxLength={80} defaultValue={d.title} /></div>
            </ActionForm>
            <ActionForm action={deleteDayAction} className="form" submit="حذف اليوم" submitClass="btn btn-ghost btn-sm danger"
              confirm={`حذف «${d.title}» بكل تمارينه${kind === "block" ? " وسجلات المتدرب فيه" : ""}؟`}>
              {hidden({ day: d.id })}
            </ActionForm>
          </div>

          {d.items.length === 0 && <p className="small muted">لا توجد تمارين في هذا اليوم بعد.</p>}
          <ol className="program-items">
            {d.items.map((it, idx) => (
              <li key={it.id}>
                <details>
                  <summary>
                    <span><bdi dir="ltr"><b>{it.name}</b></bdi>
                      {it.coach_name && <span className="status action small" style={{ marginInlineStart: 8 }}>بدّله المتدرب من <bdi dir="ltr">{it.coach_name}</bdi></span>}</span>
                    <span className="small muted">{planLabel(it.plan[0])}{it.logs ? ` · ${it.logs} تسجيل` : ""}</span>
                  </summary>
                  <ActionForm action={saveItemAction} submit="حفظ التمرين">
                    {hidden({ item: it.id })}
                    <ExercisePicker idPrefix={`ed-${it.id}`} defaultId={it.exercise_id} />
                    <div className="grid g2">
                      <div className="field"><label htmlFor={`pos-${it.id}`}>الترتيب في اليوم (من 1 إلى {d.items.length})</label>
                        <input id={`pos-${it.id}`} name="position" type="number" inputMode="numeric" min={1} max={d.items.length} defaultValue={idx + 1} style={{ maxWidth: 120 }} /></div>
                      <div className="field"><label htmlFor={`nt-${it.id}`}>ملاحظة للمتدرب (اختياري)</label>
                        <input id={`nt-${it.id}`} name="note" type="text" maxLength={500} defaultValue={it.note ?? ""} placeholder="مثال: نزول بطيء 3 ثوانٍ" /></div>
                    </div>
                    <fieldset className="field"><legend>المجموعات والتكرارات و RIR لكل أسبوع</legend>
                      <div className="plan-grid">
                        {Array.from({ length: weeks }, (_, w) => (
                          <div key={w} className="plan-week">
                            <span className="small muted">الأسبوع {w + 1}</span>
                            <input type="text" name={`w${w + 1}_reps`} aria-label={`تكرارات الأسبوع ${w + 1}`} dir="ltr" inputMode="text" placeholder="3x12" defaultValue={formatReps(it.plan[w]?.reps ?? []).replace("×", "x")} />
                            <input type="text" name={`w${w + 1}_rir`} aria-label={`RIR الأسبوع ${w + 1}`} dir="ltr" inputMode="decimal" placeholder="RIR" defaultValue={it.plan[w]?.rir ?? ""} />
                          </div>
                        ))}
                      </div>
                      <span className="hint">اكتبي 3x12 لثلاث مجموعات × 12، أو 12-10-8 لتكرارات مختلفة. اتركي الأسبوع فارغاً إن لم يكن فيه هذا التمرين.</span>
                    </fieldset>
                    <label className="check"><input type="checkbox" name="copy_first" /><span>انسخي الأسبوع 1 لكل الأسابيع عند الحفظ</span></label>
                  </ActionForm>
                  <div className="row" style={{ gap: 8, marginTop: 8 }}>
                    <ActionForm action={deleteItemAction} className="form" submit="حذف التمرين" submitClass="btn btn-ghost btn-sm danger"
                      confirm={it.logs ? `عليه ${it.logs} تسجيل من المتدرب وستُحذف. متأكدة؟` : "حذف التمرين من اليوم؟"}>{hidden({ item: it.id })}</ActionForm>
                  </div>
                </details>
              </li>
            ))}
          </ol>

          <details className="add-item">
            <summary className="btn btn-ghost btn-sm">+ إضافة تمرين</summary>
            <ActionForm action={addItemAction} submit="إضافة" resetOnSuccess>
              {hidden({ day: d.id })}
              <ExercisePicker idPrefix={`add-${d.id}`} />
              <div className="grid g3">
                <div className="field"><label htmlFor={`addp-${d.id}`}>الترتيب في اليوم</label>
                  <input key={d.items.length} type="number" id={`addp-${d.id}`} name="position" inputMode="numeric" min={1} max={d.items.length + 1} defaultValue={d.items.length + 1} /></div>
                <div className="field"><label htmlFor={`addr-${d.id}`}>المجموعات × التكرارات</label>
                  <input type="text" id={`addr-${d.id}`} name="reps" dir="ltr" placeholder="3x12" /></div>
                <div className="field"><label htmlFor={`addi-${d.id}`}>RIR</label>
                  <input type="text" id={`addi-${d.id}`} name="rir" dir="ltr" inputMode="decimal" placeholder="2" /></div>
              </div>
              <span className="hint">تُطبّق على كل الأسابيع، ثم عدّلي كل أسبوع من التمرين نفسه.</span>
            </ActionForm>
          </details>
          </div>
          </details>
        </section>
      ))}

      <div className="card">
        <ActionForm action={addDayAction} className="form inline-form" submit="+ إضافة يوم" resetOnSuccess>
          {hidden({ owner: ownerId })}
          <div className="field"><label htmlFor={`nd-${ownerId}`}>عنوان اليوم الجديد</label>
            <input id={`nd-${ownerId}`} name="title" type="text" required maxLength={80} placeholder={`DAY ${days.length + 1} — UPPER BODY`} /></div>
        </ActionForm>
      </div>
    </div>
    </ExercisesProvider>
  );
}
