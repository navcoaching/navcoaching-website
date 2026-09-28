"use client";
import { useState } from "react";
import Link from "next/link";
import { EB_GOALS as GOALS, MACRO_DEFAULTS, MACRO_LIMITS, PAF_LEVELS as PAF, PROTEIN_LEVELS, calculateIntake, macrosFor, proteinPerKg, validateIntake, validateMacroSettings, type BmrMethod, type IntakeErrors, type IntakeInput, type IntakeResult } from "@/lib/calories";

// مستويات النشاط خارج التمرين (عامل النشاط البدني). القيم إرشادية وقابلة للتعديل هنا.
const METHODS: { v: BmrMethod; t: string; d: string }[] = [
  { v: "cunningham", t: "أعرف نسبة الدهون", d: "الأدق: يعتمد على الكتلة الخالية من الدهون (معادلة Cunningham)." },
  { v: "tenhaaf", t: "ما أعرف نسبة الدهون", d: "يعتمد على الوزن والطول والعمر والجنس (معادلة Ten Haaf) — مناسبة للأشخاص الرياضيين." },
  { v: "tinsley", t: "رياضي بنية عضلية عالية", d: "للاعبي كمال الأجسام ومن في بنيتهم فقط (معادلة Tinsley)." },
];

type Raw = { method: BmrMethod; weight: string; bodyFat: string; heightCm: string; age: string; sex: "" | "male" | "female"; paf: string; minutes: string; trainingDays: string; ebFactor: string };
const EMPTY: Raw = { method: "cunningham", weight: "", bodyFat: "", heightCm: "", age: "", sex: "", paf: "1.0", minutes: "60", trainingDays: "4", ebFactor: "0.8" };
const n = (v: string) => (v.trim() === "" ? NaN : Number(v.replace(",", ".").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))));
const fmt = (v: number) => Math.round(v).toLocaleString("en-US");

export default function IntakeCalculator({ idPrefix = "i" }: { idPrefix?: string }) {
  const [raw, setRaw] = useState<Raw>(EMPTY);
  const [errors, setErrors] = useState<IntakeErrors>({});
  const [result, setResult] = useState<IntakeResult | null>(null);
  const [mp, setMp] = useState({ p: String(MACRO_DEFAULTS.proteinLevel), f: String(MACRO_DEFAULTS.fatPerKg) });
  const set = <K extends keyof Raw>(k: K, v: Raw[K]) => { setRaw((r) => ({ ...r, [k]: v })); setErrors((e) => ({ ...e, [k]: undefined })); };
  const id = (k: string) => `${idPrefix}-${k}`;

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const input = {
      method: raw.method, weight: n(raw.weight), bodyFat: n(raw.bodyFat), heightCm: n(raw.heightCm), age: n(raw.age),
      sex: raw.sex || null, paf: n(raw.paf), minutes: n(raw.minutes), trainingDays: n(raw.trainingDays), ebFactor: n(raw.ebFactor),
    };
    const errs = validateIntake(input);
    setErrors(errs);
    if (Object.keys(errs).length) { setResult(null); return; }
    setResult(calculateIntake(input as IntakeInput));
    requestAnimationFrame(() => document.getElementById(id("result"))?.scrollIntoView({ behavior: "smooth", block: "start" }));
  };

  const num = (k: "weight" | "bodyFat" | "heightCm" | "age" | "minutes", label: string, unit: string, hint?: string) => (
    <div className="field">
      <label htmlFor={id(k)}>{label} <span className="req">*</span></label>
      <div className="input-unit">
        <input id={id(k)} type="number" inputMode="decimal" step="any" value={raw[k]} onChange={(e) => set(k, e.target.value)} aria-invalid={errors[k] ? true : undefined} />
        <span aria-hidden="true">{unit}</span>
      </div>
      {hint && <span className="hint">{hint}</span>}
      {errors[k] && <span className="err-msg">{errors[k]}</span>}
    </div>
  );
  const select = (k: "paf" | "ebFactor" | "trainingDays", label: string, opts: readonly { v: string; l: string }[]) => (
    <div className="field">
      <label htmlFor={id(k)}>{label} <span className="req">*</span></label>
      <select id={id(k)} value={raw[k]} onChange={(e) => set(k, e.target.value)}>
        {opts.map((o) => <option key={o.v} value={o.v}>{o.l}</option>)}
      </select>
      {errors[k] && <span className="err-msg">{errors[k]}</span>}
    </div>
  );
  const td = Number(raw.trainingDays);
  const weight = n(raw.weight);
  const ms = { proteinPerKg: proteinPerKg(mp.p), fatPerKg: n(mp.f) };
  const msErr = validateMacroSettings(ms);
  const macroRow = (label: string, kcal: number, testId: string) => {
    const m = macrosFor(kcal, weight, ms);
    return (
      <div key={testId} className="card flat stack" style={{ ["--space" as string]: "6px" }} data-testid={testId}>
        <span><b>{label}</b> <span className="small muted num">· {fmt(kcal)} سعرة</span></span>
        <span className="row" style={{ gap: 14, flexWrap: "wrap" }}>
          <span>بروتين <b className="num">{m.protein}</b>غ</span>
          <span>كارب <b className="num">{m.carbs}</b>غ</span>
          <span>دهون <b className="num">{m.fat}</b>غ</span>
        </span>
      </div>
    );
  };

  return (
    <>
      <form className="card form calc-form" onSubmit={onSubmit} noValidate aria-label="حاسبة السعرات اليومية">
        <fieldset className="field">
          <legend>طريقة الحساب</legend>
          <div className="method-list">
            {METHODS.map((m) => (
              <label key={m.v} className={`method ${raw.method === m.v ? "on" : ""}`}>
                <input type="radio" name={id("method")} value={m.v} checked={raw.method === m.v} onChange={() => set("method", m.v)} />
                <span><b>{m.t}</b><small>{m.d}</small></span>
              </label>
            ))}
          </div>
        </fieldset>

        <div className="grid g2">
          {num("weight", "الوزن", "كغ")}
          {raw.method === "cunningham" && num("bodyFat", "نسبة الدهون", "%", "من فحص InBody أو تقدير تقريبي من صور نسب الدهون المرجعية.")}
          {raw.method === "tenhaaf" && num("heightCm", "الطول", "سم")}
          {raw.method === "tenhaaf" && num("age", "العمر", "سنة")}
        </div>
        {raw.method === "tenhaaf" && (
          <fieldset className="field">
            <legend>الجنس <span className="req">*</span></legend>
            <div className="choices">
              {([["male", "ذكر"], ["female", "أنثى"]] as const).map(([v, l]) => (
                <label key={v} className="choice"><input type="radio" name={id("sex")} value={v} checked={raw.sex === v} onChange={() => set("sex", v)} /><span>{l}</span></label>
              ))}
            </div>
            {errors.sex && <span className="err-msg">{errors.sex}</span>}
          </fieldset>
        )}

        <div className="grid g2">
          {select("paf", "نشاطك اليومي خارج التمرين", PAF)}
          {select("trainingDays", "أيام تمرين المقاومة في الأسبوع", [0, 1, 2, 3, 4, 5, 6, 7].map((d) => ({ v: String(d), l: d === 0 ? "لا أتمرن" : d === 1 ? "يوم واحد" : d === 2 ? "يومين" : `${d} أيام` })))}
          {td > 0 && num("minutes", "مدة جلسة التمرين", "دقيقة")}
          {select("ebFactor", "هدفك", GOALS)}
        </div>
        <button type="submit" className="btn btn-block">احسب السعرات</button>
      </form>

      {result && (
        <section id={id("result")} className="card stack calc-result" aria-live="polite" aria-label="النتيجة" style={{ ["--space" as string]: "16px", scrollMarginTop: 90 }}>
          <h2 style={{ fontSize: 22 }}>النتيجة</h2>
          <div className="calc-target">
            <span className="muted">متوسط سعراتك اليومية لهدفك</span>
            <b data-testid="intake-target">{fmt(result.target)}</b>
            <span className="small muted">سعرة حرارية يومياً</span>
          </div>
          <div className="grid calc-cards">
            {td > 0 && <div className="card flat stat"><span className="muted">يوم التمرين</span><b data-testid="intake-training-day">{fmt(result.trainingDayTarget)}</b><span className="small muted">سعرة</span></div>}
            {td < 7 && <div className="card flat stat"><span className="muted">يوم الراحة</span><b data-testid="intake-rest-day">{fmt(result.restDayTarget)}</b><span className="small muted">سعرة</span></div>}
            <div className="card flat stat"><span className="muted">سعرات المحافظة</span><b data-testid="intake-maintenance">{fmt(result.maintenance)}</b><span className="small muted">سعرة يومياً</span></div>
            <div className="card flat stat"><span className="muted">معدل الأيض الأساسي</span><b data-testid="intake-bmr">{fmt(result.bmr)}</b><span className="small muted">سعرة</span></div>
          </div>
          <div className="card flat stack" style={{ ["--space" as string]: "10px" }} data-testid="intake-macros">
            <h3 style={{ fontSize: 17, margin: 0 }}>الماكروز اليومية (تقدير مبدئي)</h3>
            <div className="grid g2">
              <div className="field"><label htmlFor={id("mp")}>مستوى البروتين</label>
                <select id={id("mp")} value={mp.p} onChange={(e) => setMp((m) => ({ ...m, p: e.target.value }))}>
                  {PROTEIN_LEVELS.map((o) => <option key={o.v} value={o.v}>{o.l}</option>)}
                </select></div>
              <div className="field"><label htmlFor={id("mf")}>الدهون (غ لكل كغ)</label>
                <input id={id("mf")} type="number" inputMode="decimal" step="0.1" min={MACRO_LIMITS.fatPerKg[0]} max={MACRO_LIMITS.fatPerKg[1]} value={mp.f} onChange={(e) => setMp((m) => ({ ...m, f: e.target.value }))} aria-invalid={msErr.fatPerKg ? true : undefined} />
                {msErr.fatPerKg && <span className="err-msg">{msErr.fatPerKg}</span>}</div>
            </div>
            {Object.keys(msErr).length === 0 && (
              <div className="stack" style={{ ["--space" as string]: "8px" }}>
                {macroRow("المتوسط", result.target, "macros-avg")}
                {td > 0 && macroRow("يوم التمرين", result.trainingDayTarget, "macros-training")}
                {td < 7 && macroRow("يوم الراحة", result.restDayTarget, "macros-rest")}
              </div>
            )}
            <span className="hint">البروتين والدهون ثابتة حسب وزنك، والكارب هو الباقي من السعرات (السعرات = بروتين×4 + كارب×4 + دهون×9). الأرقام مبدئية وتقدر تعدّلها، وخطتك مع المدربة تحدد المناسب لك.</span>
          </div>
          <details className="small">
            <summary style={{ cursor: "pointer", minHeight: 44 }}>كيف حسبناها؟</summary>
            <ul className="calc-steps">
              {result.ffm != null && <li>الكتلة الخالية من الدهون: {result.ffm.toFixed(1)} كغ</li>}
              <li>معدل الأيض الأساسي ({raw.method === "cunningham" ? "Cunningham 1991" : raw.method === "tinsley" ? "Tinsley 2018" : "Ten Haaf 2014"}): {fmt(result.bmr)} سعرة</li>
              {td > 0 && <li>مصروف التمرين: 0.1 × الوزن × مدة الجلسة = {fmt(result.trainingEE)} سعرة</li>}
              <li>يوم الراحة = الأيض × عامل النشاط × 1.2 (التأثير الحراري للطعام) = {fmt(result.restDayEE)}</li>
              {td > 0 && <li>يوم التمرين = (الأيض × عامل النشاط + مصروف التمرين) × 1.2 = {fmt(result.trainingDayEE)}</li>}
              <li>المحافظة = متوسط الأسبوع؛ والهدف = المحافظة × {raw.ebFactor}</li>
              <li>الماكروز: بروتين = (1.6 للمعتدل أو 2.2 للعالي) غ/كغ × الوزن، ودهون = غ/كغ × الوزن، والكارب = (السعرات − بروتين×4 − دهون×9) ÷ 4.</li>
              <li>معادلات السعرات من حاسبة Menno Henselmans (Energy Intake Calculator).</li>
            </ul>
          </details>
          <p className="small muted">نقطة بداية تقريبية: راقب وزنك وقياساتك أسبوعين إلى ثلاثة، وعدّل حسب النتيجة. بعد فترة تقدر تحسب سعراتك الفعلية بدقة من <Link href="/calculator#energy-balance">حاسبة توازن الطاقة</Link>.</p>
          <div className="alert info calc-cta">
            <span>تبي خطة تدريب وتغذية مبنية على أرقامك مع متابعة أسبوعية؟</span>
            <Link href="/programs" className="btn btn-sm">شوف البرامج</Link>
          </div>
        </section>
      )}
    </>
  );
}
