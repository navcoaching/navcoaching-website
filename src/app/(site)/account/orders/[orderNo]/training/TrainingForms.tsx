"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import {
  logItemAction, logMeasurementsAction, logStepsAction, logWeightAction, rateDayAction, readWorkoutImageAction, saveImportedLogsAction, swapExerciseAction,
  type ImportPreview,
} from "@/app/actions/training";
import { MAX_SETS, bestOneRm } from "@/lib/training";
import FilePicker from "@/components/FilePicker";

type Log = { weight: number; weights: number[] | null; reps: number[]; rir: number | null } | null;

/** تسجيل تمرين لأسبوع: وزن وتكرارات لكل جولة، و RIR. الوزن الفارغ = وزن الجولة السابقة، والتكرارات الفارغة = المستهدف */
export function ItemLogForm({ orderNo, item, week, target, targetRir, log }: {
  orderNo: string; item: string; week: number; target: number[]; targetRir: number | null; log: Log;
}) {
  const { state, onSubmit, pending } = useFormAction(logItemAction);
  const initialSets = Math.max(target.length, log?.reps.length ?? 0, log?.weights?.length ?? 0, 1);
  const [sets, setSets] = useState(initialSets);
  const [w, setW] = useState<string[]>(() => Array.from({ length: MAX_SETS }, (_, i) =>
    log ? String(log.weights?.[i] ?? (i === 0 || !log.weights ? log.weight : "")) : ""));
  const [r, setR] = useState<string[]>(() => Array.from({ length: MAX_SETS }, (_, i) => (log?.reps[i] != null ? String(log.reps[i]) : "")));
  // الجولات اللي عدّلها المتدرب بنفسه (ما تتغيّر تلقائياً). التسجيل المحفوظ يُعتبر معدّلاً
  const [tw, setTw] = useState<boolean[]>(() => Array.from({ length: MAX_SETS }, () => Boolean(log)));
  const [tr, setTr] = useState<boolean[]>(() => Array.from({ length: MAX_SETS }, () => Boolean(log)));
  /** كتابة وزن/تكرارات جولة: الجولات اللي بعدها (غير المعدّلة) تأخذ نفس القيمة تلقائياً */
  const typed = (kind: "w" | "r", i: number, v: string) => {
    const touched = kind === "w" ? tw : tr;
    (kind === "w" ? setW : setR)((a) => a.map((x, j) => (j === i || (j > i && !touched[j]) ? v : x)));
    (kind === "w" ? setTw : setTr)((a) => a.map((x, j) => (j === i ? true : x)));
  };
  const p = `${item}-${week}`;
  // 1RM مباشر من المدخلات (الفارغ يأخذ السابق/المستهدف)
  const num = (v: string) => { const n = Number(v.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(",", ".")); return v.trim() && Number.isFinite(n) ? n : null; };
  let lastW = 0;
  const ws: number[] = [], rs: number[] = [];
  for (let i = 0; i < sets; i++) { lastW = num(w[i]) ?? lastW; const rr = num(r[i]) ?? target[i]; if (rr != null) { ws.push(lastW); rs.push(rr); } }
  const est = num(w[0]) != null ? bestOneRm(ws, rs) : 0;
  // القيمة الفعلية لجولة (الفارغ = السابق للوزن، والمستهدف للتكرارات)
  const effW = (i: number) => { let v: number | null = null; for (let j = 0; j <= i; j++) v = num(w[j]) ?? v; return v; };
  const effR = (i: number) => num(r[i]) ?? target[i] ?? null;
  /** تكرار الجولة: جولة جديدة بعدها بنفس الوزن والتكرارات (مثل Hevy) */
  const duplicate = (i: number) => {
    if (sets >= MAX_SETS) return;
    const ins = <T,>(a: T[], v: T) => [...a.slice(0, i + 1), v, ...a.slice(i + 1)].slice(0, MAX_SETS);
    setW((a) => ins(a, effW(i) != null ? String(effW(i)) : ""));
    setR((a) => ins(a, effR(i) != null ? String(effR(i)) : ""));
    setTw((a) => ins(a, true));
    setTr((a) => ins(a, true));
    setSets(sets + 1);
  };
  return (
    <form className="form log-form" onSubmit={onSubmit} data-testid={`log-${item}`}>
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="item" value={item} />
      <input type="hidden" name="week" value={week} />
      <div className="set-rows" role="group" aria-label="الجولات">
        <div className="set-row set-head small muted" aria-hidden="true"><span>الجولة</span><span>الوزن (كغ)</span><span /><span>التكرارات</span><span /></div>
        {Array.from({ length: sets }, (_, i) => (
          <div className="set-row" key={i}>
            <span className="set-no">{i + 1}</span>
            <input name="set_weight" type="text" inputMode="decimal" dir="ltr" aria-label={`وزن الجولة ${i + 1}`} value={w[i]} required={i === 0}
              placeholder={i > 0 ? (num(w[i - 1]) != null ? w[i - 1] : "نفس السابق") : "كغ"} onChange={(e) => typed("w", i, e.target.value)} />
            <span className="muted" aria-hidden="true">×</span>
            <input name="reps" type="text" inputMode="numeric" dir="ltr" aria-label={`تكرارات الجولة ${i + 1}`} value={r[i]}
              placeholder={target[i] != null ? String(target[i]) : ""} onChange={(e) => typed("r", i, e.target.value)} />
            <button type="button" className="set-dup" onClick={() => duplicate(i)} disabled={sets >= MAX_SETS}
              aria-label={`تكرار الجولة ${i + 1}`} title="تكرار الجولة بنفس الوزن والعدّات">⧉</button>
          </div>
        ))}
        <div className="row" style={{ gap: 8 }}>
          {sets < MAX_SETS && <button type="button" className="btn btn-ghost btn-sm" onClick={() => duplicate(sets - 1)}>+ جولة</button>}
          {sets > Math.max(1, target.length) && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setSets(sets - 1)}>− جولة</button>}
        </div>
      </div>
      <div className="field rir-field">
        <label htmlFor={`r-${p}`}>RIR</label>
        <input id={`r-${p}`} name="rir" type="number" inputMode="decimal" step="0.5" min={0} max={10} dir="ltr" placeholder={targetRir != null ? String(targetRir) : ""} defaultValue={log?.rir ?? ""} />
      </div>
      <p className="hint" style={{ margin: 0 }}>اكتب وزن وعدّات الجولة الأولى وتتعبّى الجولات اللي بعدها تلقائياً، وعدّل أي جولة اختلفت. ⧉ يكرر الجولة.</p>
      {est > 0 && <p className="small one-rm" data-testid="one-rm" style={{ margin: 0 }}>🏆 أعلى وزن تقديري لتكرار واحد (1RM): <b className="num">{est}</b> كغ</p>}
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
  const router = useRouter();
  // بعد حفظ التقييم (نهاية تمرين اليوم) يرجع المتدرب لصفحة حسابه الرئيسية
  useEffect(() => {
    if (!state.ok) return;
    const t = setTimeout(() => router.push("/account"), 900);
    return () => clearTimeout(t);
  }, [state, router]);
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

/** تصغير الصورة في الجهاز قبل الرفع (أسرع، وتحت حد حجم الطلب في الخادم). عند أي فشل نرفع الأصل. */
async function shrinkImage(file: File, maxSide = 2000, keepUnder = 1_500_000): Promise<File> {
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, maxSide / Math.max(bmp.width, bmp.height));
    if (scale === 1 && file.size <= keepUnder) return file;
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext("2d")!.drawImage(bmp, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, "image/jpeg", 0.85));
    return blob ? new File([blob], "workout.jpg", { type: "image/jpeg" }) : file;
  } catch {
    return file;
  }
}

function ImportFlow({ orderNo, day, week, again }: { orderNo: string; day: string; week: number; again: () => void }) {
  const [preview, setPreview] = useState<ImportPreview>({});
  const [reading, setReading] = useState(false);
  const save = useFormAction(saveImportedLogsAction);
  const rows = preview.rows ?? [];
  const onRead = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (reading) return;
    const fd = new FormData(e.currentTarget);
    const files = fd.getAll("image").filter((f): f is File => f instanceof File && f.size > 0);
    if (files.length > 4) { setPreview({ error: "اختر حتى 4 صور." }); return; }
    fd.delete("image");
    // تصغير كل صورة (أكثر من صورة ← تصغير أقوى حتى يبقى المجموع تحت حد الخادم)
    for (const f of files) fd.append("image", await shrinkImage(f, files.length > 1 ? 1600 : 2000, files.length > 1 ? 600_000 : 1_500_000));
    setReading(true);
    try {
      // استدعاء مباشر مع التقاط الخطأ: انقطاع الاتصال أو طول القراءة يظهر كرسالة، لا صفحة خطأ
      setPreview(await readWorkoutImageAction({}, fd));
    } catch {
      setPreview({ error: "طالت قراءة الصورة أو انقطع الاتصال. جرّب مرة ثانية بلقطة شاشة واضحة، أو سجّل يدوياً." });
    } finally {
      setReading(false);
    }
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
                <label htmlFor={`img-${day}`}>لقطات شاشة لتمرين اليوم من تطبيقك (حتى 4 صور)</label>
                <FilePicker id={`img-${day}`} name="image" accept="image/png,image/jpeg,image/webp" multiple required maxMb={40} hint="حتى 4 صور (تُصغَّر تلقائياً)" />
                <span className="hint">إذا التمرين طويل اختر اللقطات بالترتيب. نقرأ التمارين والأوزان والتكرارات، وتراجعها قبل الحفظ. الصور لا تُحفظ في الموقع، وتُرسل لخدمة قراءة الصور (Anthropic) للقراءة فقط.</span>
              </div>
              {preview.error && <p className="alert err" role="alert">{preview.error}</p>}
              <div><Submit className="btn btn-sm" pending={reading} pendingText="جارٍ قراءة الصور… (حتى 30 ثانية)">اقرأ الصورة</Submit></div>
            </form>

            {rows.length > 0 && (
              <form onSubmit={save.onSubmit} className="form import-review" data-testid="import-review" key={rows.map((r) => r.key).join("|")}>
                <input type="hidden" name="order_no" value={orderNo} />
                <input type="hidden" name="week" value={week} />
                <input type="hidden" name="count" value={rows.length} />
                <p className="small muted" style={{ margin: 0 }}>راجع الأرقام قبل الحفظ. الأوزان والتكرارات لكل جولة بالترتيب (بالكيلو)، والإحماء لا يُحسب.</p>
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
                      <div className="field"><label htmlFor={`w-${k}`}>الأوزان (كغ)</label>
                        <input id={`w-${k}`} name={`weights_${k}`} type="text" inputMode="decimal" dir="ltr" defaultValue={r.weights.join(", ")} /></div>
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

/** بطاقة تمرين قابلة للطي: الحالة الأولى من الخادم (أول تمرين غير مسجّل مفتوح)، وبعدها يتحكم فيها المتدرب
 *  (ما تنطوي لحالها بعد الحفظ، فتبقى رسالة «تم الحفظ» ظاهرة) */
export function ExerciseDetails({ defaultOpen, children, summary }: { defaultOpen: boolean; children: React.ReactNode; summary: React.ReactNode }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <details className="card exercise-card" open={open} onToggle={(e) => setOpen(e.currentTarget.open)} data-testid="exercise-card">
      <summary className="exercise-summary">{summary}</summary>
      {children}
    </details>
  );
}
