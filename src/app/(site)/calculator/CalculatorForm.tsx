"use client";
import { useState } from "react";
import Link from "next/link";
import { calculateCalories, validate, LIMITS, type CalorieInput, type CalorieResult, type FieldErrors } from "@/lib/calories";

type Raw = Record<"sex" | "age" | "weight" | "height" | "bodyFat" | "steps" | "goal" | "level" | "protein", string>;
const EMPTY: Raw = { sex: "", age: "", weight: "", height: "", bodyFat: "", steps: "", goal: "", level: "", protein: "moderate" };
const n = (v: string) => (v.trim() === "" ? NaN : Number(v.replace(",", ".")));
const fmt = (v: number) => Math.round(v).toLocaleString("en-US");

function Choice({ name, value, label, raw, set }: { name: keyof Raw; value: string; label: string; raw: Raw; set: (k: keyof Raw, v: string) => void }) {
  return (
    <label className="choice">
      <input type="radio" name={name} value={value} checked={raw[name] === value} onChange={() => set(name, value)} />
      <span>{label}</span>
    </label>
  );
}

export default function CalculatorForm() {
  const [raw, setRaw] = useState<Raw>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [result, setResult] = useState<CalorieResult | null>(null);
  const set = (k: keyof Raw, v: string) => { setRaw((r) => ({ ...r, [k]: v })); setErrors((e) => ({ ...e, [k]: undefined })); };

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const input = {
      sex: raw.sex, age: n(raw.age), weight: n(raw.weight), height: n(raw.height),
      bodyFat: raw.bodyFat.trim() === "" ? null : n(raw.bodyFat), steps: n(raw.steps),
      goal: raw.goal, level: raw.level, protein: raw.protein,
    };
    const errs = validate(input);
    setErrors(errs);
    if (Object.keys(errs).length) {
      setResult(null);
      requestAnimationFrame(() => document.querySelector<HTMLElement>("[aria-invalid='true'], .calc-form .err-msg")?.scrollIntoView({ behavior: "smooth", block: "center" }));
      return;
    }
    setResult(calculateCalories(input as CalorieInput));
    requestAnimationFrame(() => document.getElementById("calc-result")?.scrollIntoView({ behavior: "smooth", block: "start" }));
  };

  const field = (k: "age" | "weight" | "height" | "bodyFat" | "steps", label: string, unit: string, hint?: string, optional = false) => (
    <div className="field">
      <label htmlFor={`c-${k}`}>{label} {optional ? <span className="muted small">(اختياري)</span> : <span className="req">*</span>}</label>
      <div className="input-unit">
        <input id={`c-${k}`} name={k} type="number" inputMode="decimal" step="any" min={LIMITS[k][0]} max={LIMITS[k][1]}
          value={raw[k]} onChange={(e) => set(k, e.target.value)} aria-invalid={errors[k] ? true : undefined} aria-describedby={hint ? `c-${k}-hint` : undefined} />
        <span aria-hidden="true">{unit}</span>
      </div>
      {hint && <span className="hint" id={`c-${k}-hint`}>{hint}</span>}
      {errors[k] && <span className="err-msg">{errors[k]}</span>}
    </div>
  );

  const kcal = result ? { p: result.proteinG * 4, f: result.fatG * 9, c: result.carbsG * 4 } : null;
  const total = kcal ? kcal.p + kcal.f + kcal.c : 1;

  return (
    <>
      <form className="card form calc-form" onSubmit={onSubmit} noValidate aria-labelledby="calc-h">
        <h2 id="calc-h" style={{ fontSize: 22 }}>تركيبة الجسم</h2>
        <fieldset className="field">
          <legend>الجنس <span className="req">*</span></legend>
          <div className="choices">
            <Choice name="sex" value="male" label="ذكر" raw={raw} set={set} />
            <Choice name="sex" value="female" label="أنثى" raw={raw} set={set} />
          </div>
          {errors.sex && <span className="err-msg">{errors.sex}</span>}
        </fieldset>
        <div className="grid g3">
          {field("age", "العمر", "سنة")}
          {field("weight", "الوزن", "كغ")}
          {field("height", "الطول", "سم")}
        </div>
        <div className="grid g2">
          {field("bodyFat", "نسبة الدهون", "%", "يمكنك معرفة نسبة الدهون من خلال فحص InBody أو تقدير تقريبي من مخططات نسبة الدهون المرجعية على الإنترنت.", true)}
          {field("steps", "عدد الخطوات اليومية", "خطوة", "يمكنك معرفته من تطبيق الخطوات في هاتفك أو ساعتك الرياضية (خذ المتوسط لأسبوع).")}
        </div>

        <h2 style={{ fontSize: 22, marginTop: 8 }}>هدفك</h2>
        <div className="grid g2">
          <div className="field">
            <label htmlFor="c-goal">الهدف الرئيسي <span className="req">*</span></label>
            <select id="c-goal" value={raw.goal} onChange={(e) => set("goal", e.target.value)} aria-invalid={errors.goal ? true : undefined}>
              <option value="" disabled>اختر…</option>
              <option value="gain">زيادة الوزن / تضخيم</option>
              <option value="lose">نزول الوزن / تنشيف</option>
              <option value="maintain">المحافظة على الوزن</option>
            </select>
            {errors.goal && <span className="err-msg">{errors.goal}</span>}
          </div>
          <div className="field">
            <label htmlFor="c-level">مستواك في تمارين المقاومة <span className="req">*</span></label>
            <select id="c-level" value={raw.level} onChange={(e) => set("level", e.target.value)} aria-invalid={errors.level ? true : undefined}>
              <option value="" disabled>اختر…</option>
              <option value="beginner">مبتدئ (أقل من سنة)</option>
              <option value="advanced">متقدم (سنة أو أكثر)</option>
            </select>
            {errors.level && <span className="err-msg">{errors.level}</span>}
          </div>
        </div>
        <fieldset className="field">
          <legend>كمية البروتين</legend>
          <div className="choices">
            <Choice name="protein" value="moderate" label="بروتين معتدل" raw={raw} set={set} />
            <Choice name="protein" value="high" label="بروتين عالي" raw={raw} set={set} />
          </div>
        </fieldset>
        <button type="submit" className="btn btn-block">احسب السعرات الحرارية</button>
      </form>

      {result && kcal && (
        <section id="calc-result" className="card stack calc-result" aria-live="polite" aria-labelledby="res-h" style={{ ["--space" as string]: "16px" }}>
          <h2 id="res-h" style={{ fontSize: 22 }}>نتيجتك</h2>
          <div className="calc-target">
            <span className="muted">سعرات هدفك اليومية</span>
            <b data-testid="calc-target">{fmt(result.target)}</b>
            <span className="small muted">سعرة حرارية</span>
          </div>
          <div className="grid g4 calc-cards">
            <div className="card flat stat"><span className="muted">سعرات المحافظة على الوزن</span><b data-testid="calc-tdee">{fmt(result.tdee)}</b><span className="small muted">سعرة</span></div>
            <div className="card flat stat m-p"><span className="muted">البروتين</span><b data-testid="calc-protein">{fmt(result.proteinG)}</b><span className="small muted">غرام · {fmt(kcal.p)} سعرة</span></div>
            <div className="card flat stat m-f"><span className="muted">الدهون</span><b data-testid="calc-fat">{fmt(result.fatG)}</b><span className="small muted">غرام · {fmt(kcal.f)} سعرة</span></div>
            <div className="card flat stat m-c"><span className="muted">الكربوهيدرات</span><b data-testid="calc-carbs">{fmt(result.carbsG)}</b><span className="small muted">غرام · {fmt(kcal.c)} سعرة</span></div>
          </div>
          <div className="macro-bar" role="img" aria-label={`توزيع السعرات: بروتين ${Math.round((kcal.p / total) * 100)}٪، دهون ${Math.round((kcal.f / total) * 100)}٪، كربوهيدرات ${Math.round((kcal.c / total) * 100)}٪`}>
            <span className="m-p" style={{ width: `${(kcal.p / total) * 100}%` }} />
            <span className="m-f" style={{ width: `${(kcal.f / total) * 100}%` }} />
            <span className="m-c" style={{ width: `${(kcal.c / total) * 100}%` }} />
          </div>
          {result.warnings.map((w) => <p key={w} className="alert warn">{w}</p>)}
          <details className="small">
            <summary style={{ cursor: "pointer", minHeight: 44 }}>كيف حسبناها؟</summary>
            <ul className="calc-steps">
              <li>الكتلة الخالية من الدهون: {result.lbm.toFixed(1)} كغ{result.lbmEstimated ? " (تقدير = الوزن الكلي)" : ""}</li>
              <li>معدل الأيض الأساسي ({result.formula === "katch" ? "معادلة Katch-McArdle" : "معادلة Mifflin-St Jeor"}): {fmt(result.bmr)} سعرة</li>
              <li>عامل النشاط حسب خطواتك: {result.activity}</li>
              <li>البروتين: {result.proteinPerKg} غ لكل كغ من الكتلة الخالية · الدهون: 27٪ من سعرات الهدف · الكربوهيدرات: الباقي</li>
            </ul>
          </details>
          <div className="alert info calc-cta">
            <span>تبي خطة تدريب وتغذية مبنية على أرقامك مع متابعة أسبوعية؟</span>
            <Link href="/programs" className="btn btn-sm">شوف البرامج</Link>
          </div>
        </section>
      )}
    </>
  );
}
