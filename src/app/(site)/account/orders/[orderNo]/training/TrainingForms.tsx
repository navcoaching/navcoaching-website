"use client";
import { startTransition, useActionState, useState } from "react";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import {
  logItemAction, logMeasurementsAction, logStepsAction, logWeightAction, rateDayAction, readWorkoutImageAction, saveImportedLogsAction, swapExerciseAction,
  type ImportPreview,
} from "@/app/actions/training";

type Log = { weight: number; reps: number[]; rir: number | null } | null;

/** تسجيل تمرين لأسبوع: الوزن (أساسي) والتكرارات الفعلية و RIR (اختياري: الفارغ = المستهدف) */
export function ItemLogForm({ orderNo, item, week, target, targetRir, log }: {
  orderNo: string; item: string; week: number; target: number[]; targetRir: number | null; log: Log;
}) {
  const { state, onSubmit, pending } = useFormAction(logItemAction);
  const sets = Math.max(target.length, log?.reps.length ?? 0, 1);
  const p = `${item}-${week}`;
  return (
    <form className="form log-form" onSubmit={onSubmit} data-testid={`log-${item}`}>
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="item" value={item} />
      <input type="hidden" name="week" value={week} />
      <div className="log-fields">
        <div className="field">
          <label htmlFor={`w-${p}`}>الوزن (كغ)</label>
          <input id={`w-${p}`} name="weight" type="number" inputMode="decimal" step="0.25" min={0} max={1000} dir="ltr" defaultValue={log?.weight ?? ""} required />
        </div>
        <fieldset className="field reps-field">
          <legend>التكرارات لكل مجموعة</legend>
          <div className="reps-inputs">
            {Array.from({ length: sets }, (_, i) => (
              <input key={i} name="reps" type="number" inputMode="numeric" min={0} max={200} dir="ltr" aria-label={`مجموعة ${i + 1}`}
                placeholder={target[i] != null ? String(target[i]) : ""} defaultValue={log?.reps[i] ?? ""} />
            ))}
          </div>
        </fieldset>
        <div className="field">
          <label htmlFor={`r-${p}`}>RIR</label>
          <input id={`r-${p}`} name="rir" type="number" inputMode="decimal" step="0.5" min={0} max={10} dir="ltr" placeholder={targetRir != null ? String(targetRir) : ""} defaultValue={log?.rir ?? ""} />
        </div>
      </div>
      <p className="hint" style={{ margin: 0 }}>اترك التكرارات أو RIR فارغة إذا كانت مثل المستهدف.</p>
      <FormMessage state={state} />
      <div className="row" style={{ gap: 8 }}>
        <Submit pending={pending} className="btn btn-sm">{log ? "تحديث" : "حفظ"}</Submit>
        {log && <button type="submit" name="clear" value="1" className="btn btn-ghost btn-sm" formNoValidate disabled={pending}>حذف التسجيل</button>}
      </div>
    </form>
  );
}

/** تبديل التمرين ببديل من قائمة المدربة */
export function SwapForm({ orderNo, item, options, current }: {
  orderNo: string; item: string; options: { id: string; name: string; is_coach_choice: boolean }[]; current: string;
}) {
  const [value, setValue] = useState(current);
  const { state, onSubmit, pending } = useFormAction(swapExerciseAction, () =>
    window.confirm(`تبديل التمرين إلى «${options.find((o) => o.id === value)?.name}»؟ يسري على بقية أسابيع البرنامج، وتصل المدربة ملاحظة بالتبديل.`));
  if (options.length < 2) return null;
  return (
    <form className="form swap-form" onSubmit={onSubmit} data-testid={`swap-${item}`}>
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="item" value={item} />
      <div className="field">
        <label htmlFor={`sw-${item}`}>تبديل بتمرين بديل</label>
        <div className="row" style={{ gap: 8, flexWrap: "nowrap" }}>
          <select id={`sw-${item}`} name="exercise" value={value} onChange={(e) => setValue(e.target.value)} dir="ltr">
            {options.map((o) => <option key={o.id} value={o.id}>{o.name}{o.is_coach_choice ? " (اختيار المدربة)" : ""}</option>)}
          </select>
          <Submit pending={pending} className="btn btn-ghost btn-sm" disabled={value === current || pending}>تبديل</Submit>
        </div>
      </div>
      <FormMessage state={state} />
    </form>
  );
}

export function RateDayForm({ orderNo, day, week, rating }: { orderNo: string; day: string; week: number; rating: number | null }) {
  const { state, onSubmit, pending } = useFormAction(rateDayAction);
  return (
    <form className="form" onSubmit={onSubmit} data-testid="rate-day">
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="day" value={day} />
      <input type="hidden" name="week" value={week} />
      <fieldset className="field">
        <legend>تقييم تمرين اليوم (1 مرهق · 5 ممتاز)</legend>
        <div className="choices rating-choices">
          {[1, 2, 3, 4, 5].map((n) => (
            <label key={n} className="choice"><input type="radio" name="rating" value={n} defaultChecked={rating === n} required /><span>{n}</span></label>
          ))}
        </div>
      </fieldset>
      <FormMessage state={state} />
      <div><Submit pending={pending} className="btn btn-sm">حفظ التقييم</Submit></div>
    </form>
  );
}

export function WeightForm({ orderNo, today }: { orderNo: string; today: string }) {
  const { state, onSubmit, pending } = useFormAction(logWeightAction);
  return (
    <form className="form" onSubmit={onSubmit} data-testid="weight-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <div className="grid g2">
        <div className="field"><label htmlFor="bw-date">التاريخ</label><input id="bw-date" name="date" type="date" max={today} defaultValue={today} required /></div>
        <div className="field"><label htmlFor="bw-kg">الوزن (كغ)</label><input id="bw-kg" name="kg" type="number" inputMode="decimal" step="0.1" min={25} max={350} dir="ltr" required /></div>
      </div>
      <p className="hint" style={{ margin: 0 }}>الأفضل 3 مرات بالأسبوع، الصبح بعد دورة المياه وقبل الأكل.</p>
      <FormMessage state={state} />
      <div><Submit pending={pending} className="btn btn-sm">حفظ الوزن</Submit></div>
    </form>
  );
}

export function MeasureForm({ orderNo, today }: { orderNo: string; today: string }) {
  const { state, onSubmit, pending } = useFormAction(logMeasurementsAction);
  const f = (k: string, l: string) => (
    <div className="field"><label htmlFor={`bm-${k}`}>{l} (سم)</label><input id={`bm-${k}`} name={k} type="number" inputMode="decimal" step="0.1" min={20} max={250} dir="ltr" /></div>
  );
  return (
    <form className="form" onSubmit={onSubmit} data-testid="body-measure-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <div className="field"><label htmlFor="bm-date">التاريخ</label><input id="bm-date" name="date" type="date" max={today} defaultValue={today} required /></div>
      <div className="grid g2">{f("waist", "الخصر")}{f("hips", "الحوض")}{f("chest", "الصدر")}{f("thigh", "الفخذ")}</div>
      <FormMessage state={state} />
      <div><Submit pending={pending} className="btn btn-sm">حفظ القياسات</Submit></div>
    </form>
  );
}

export function StepsForm({ orderNo, block, weeks, week, values }: { orderNo: string; block: string; weeks: number; week: number; values: Record<number, number> }) {
  const [w, setW] = useState(Math.max(1, week));
  const { state, onSubmit, pending } = useFormAction(logStepsAction);
  return (
    <form className="form" onSubmit={onSubmit} data-testid="steps-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="block" value={block} />
      <div className="grid g2">
        <div className="field"><label htmlFor="st-week">الأسبوع</label>
          <select id="st-week" name="week" value={w} onChange={(e) => setW(Number(e.target.value))}>
            {Array.from({ length: weeks }, (_, i) => <option key={i} value={i + 1}>الأسبوع {i + 1}</option>)}
          </select></div>
        <div className="field"><label htmlFor="st-total">مجموع خطوات الأسبوع</label>
          <input key={w} id="st-total" name="total" type="number" inputMode="numeric" min={0} max={500000} dir="ltr" defaultValue={values[w] ?? ""} required /></div>
      </div>
      <FormMessage state={state} />
      <div><Submit pending={pending} className="btn btn-sm">حفظ الخطوات</Submit></div>
    </form>
  );
}

const HOW: Record<string, [string, string]> = {
  alias: ["مربوط سابقاً", "ok"], name: ["مطابقة بالاسم", "ok"], partial: ["مطابقة تقريبية — تأكد", "action"],
};

/** تعبئة تسجيل اليوم من لقطة شاشة تطبيق خارجي (Strong وغيره): قراءة ← مراجعة وربط ← حفظ */
export function ImportFromImage({ orderNo, day, week }: { orderNo: string; day: string; week: number }) {
  const [round, setRound] = useState(0);
  return (
    <details className="card import-image" data-testid="import-image">
      <summary style={{ cursor: "pointer", minHeight: 44, fontWeight: 700 }}>📷 تعبئة من صورة (Strong وغيره)</summary>
      <ImportFlow key={round} orderNo={orderNo} day={day} week={week} again={() => setRound((r) => r + 1)} />
    </details>
  );
}

function ImportFlow({ orderNo, day, week, again }: { orderNo: string; day: string; week: number; again: () => void }) {
  const [preview, read, reading] = useActionState<ImportPreview, FormData>(readWorkoutImageAction, {});
  const save = useFormAction(saveImportedLogsAction);
  const rows = preview.rows ?? [];
  const onRead = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (reading) return;
    const fd = new FormData(e.currentTarget);
    startTransition(() => read(fd));
  };
  const done = save.state.ok;
  return (
      <div className="stack" style={{ ["--space" as string]: "12px", marginTop: 10 }}>
        {done ? (
          <>
            <FormMessage state={save.state} />
            <button type="button" className="btn btn-ghost btn-sm" style={{ width: "fit-content" }} onClick={again}>صورة أخرى</button>
          </>
        ) : (
          <>
            <form onSubmit={onRead} className="form">
              <input type="hidden" name="order_no" value={orderNo} />
              <input type="hidden" name="day" value={day} />
              <div className="field">
                <label htmlFor={`img-${day}`}>لقطة شاشة لتمرين اليوم من تطبيقك</label>
                <input id={`img-${day}`} name="image" type="file" accept="image/png,image/jpeg,image/webp" required />
                <span className="hint">نقرأ التمارين والأوزان والتكرارات، وتراجعها قبل الحفظ. الصورة لا تُحفظ في الموقع، وتُرسل لخدمة قراءة الصور (Anthropic) للقراءة فقط.</span>
              </div>
              {preview.error && <p className="alert err" role="alert">{preview.error}</p>}
              <div><Submit className="btn btn-sm" pending={reading} pendingText="جارٍ قراءة الصورة… (حتى 30 ثانية)">اقرأ الصورة</Submit></div>
            </form>

            {rows.length > 0 && (
              <form onSubmit={save.onSubmit} className="form import-review" data-testid="import-review" key={rows.map((r) => r.key).join("|")}>
                <input type="hidden" name="order_no" value={orderNo} />
                <input type="hidden" name="week" value={week} />
                <input type="hidden" name="count" value={rows.length} />
                <p className="small muted" style={{ margin: 0 }}>راجع الأرقام قبل الحفظ. الوزن = أثقل مجموعة عمل بالكيلو، والإحماء لا يُحسب.</p>
                {rows.map((r, k) => (
                  <fieldset key={k} className="import-row">
                    <legend><bdi dir="ltr">{r.external}</bdi>{" "}
                      {r.how ? <span className={`status ${HOW[r.how][1]}`}>{HOW[r.how][0]}</span> : <span className="status muted">اختر التمرين</span>}</legend>
                    <input type="hidden" name={`key_${k}`} value={r.key} />
                    <input type="hidden" name={`how_${k}`} value={r.how ?? ""} />
                    <div className="field">
                      <label htmlFor={`it-${k}`}>يقابله في برنامجك</label>
                      <select id={`it-${k}`} name={`item_${k}`} defaultValue={r.itemId ?? ""}>
                        <option value="">تجاهل</option>
                        {(preview.items ?? []).map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
                      </select>
                    </div>
                    <div className="import-nums">
                      <div className="field"><label htmlFor={`w-${k}`}>الوزن (كغ)</label>
                        <input id={`w-${k}`} name={`weight_${k}`} type="text" inputMode="decimal" dir="ltr" defaultValue={r.weight ?? ""} /></div>
                      <div className="field"><label htmlFor={`r-${k}`}>التكرارات</label>
                        <input id={`r-${k}`} name={`reps_${k}`} type="text" inputMode="numeric" dir="ltr" defaultValue={r.reps.join(", ")} /></div>
                      <div className="field"><label htmlFor={`rir-${k}`}>RIR</label>
                        <input id={`rir-${k}`} name={`rir_${k}`} type="text" inputMode="decimal" dir="ltr" defaultValue={r.rir ?? ""} /></div>
                    </div>
                  </fieldset>
                ))}
                <FormMessage state={save.state} />
                <div><Submit className="btn" pending={save.pending} pendingText="جارٍ الحفظ…">حفظ الكل</Submit></div>
              </form>
            )}
          </>
        )}
      </div>
  );
}
