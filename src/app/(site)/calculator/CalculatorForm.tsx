"use client";
import { useState } from "react";
import Link from "next/link";
import { calculateEnergyBalance, validate, type EnergyInput, type EnergyResult, type FieldErrors } from "@/lib/calories";

type Raw = {
  leanDir: "up" | "down"; lean: string; fatDir: "up" | "down"; fat: string;
  startDate: string; endDate: string; trainingKcal: string; trainingDays: string; restKcal: string;
};
const EMPTY: Raw = { leanDir: "up", lean: "", fatDir: "down", fat: "", startDate: "", endDate: "", trainingKcal: "", trainingDays: "4", restKcal: "" };
const n = (v: string) => (v.trim() === "" ? NaN : Number(v.replace(",", ".").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))));
const fmt = (v: number) => Math.round(v).toLocaleString("en-US");
const signed = (v: number) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${fmt(Math.abs(v))}`;

export default function CalculatorForm({ compact = false }: { compact?: boolean }) {
  const [raw, setRaw] = useState<Raw>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [result, setResult] = useState<EnergyResult | null>(null);
  const set = <K extends keyof Raw>(k: K, v: Raw[K]) => { setRaw((r) => ({ ...r, [k]: v })); setErrors((e) => ({ ...e, leanChange: undefined, fatChange: undefined, [k]: undefined })); };
  const id = (k: string) => `${compact ? "h" : "c"}-${k}`;

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const lean = n(raw.lean), fat = n(raw.fat);
    const input = {
      leanChange: Number.isNaN(lean) ? NaN : (raw.leanDir === "down" ? -1 : 1) * Math.abs(lean),
      fatChange: Number.isNaN(fat) ? NaN : (raw.fatDir === "down" ? -1 : 1) * Math.abs(fat),
      startDate: raw.startDate, endDate: raw.endDate,
      trainingKcal: n(raw.trainingKcal), trainingDays: n(raw.trainingDays), restKcal: n(raw.restKcal),
    };
    const errs = validate(input);
    setErrors(errs);
    if (Object.keys(errs).length) { setResult(null); return; }
    setResult(calculateEnergyBalance(input as EnergyInput));
    requestAnimationFrame(() => document.getElementById(id("result"))?.scrollIntoView({ behavior: "smooth", block: "start" }));
  };

  const change = (k: "lean" | "fat", dirKey: "leanDir" | "fatDir", errKey: "leanChange" | "fatChange", label: string, hint: string) => (
    <fieldset className="field">
      <legend>{label} <span className="req">*</span></legend>
      <div className="change-row">
        <div className="choices" role="radiogroup" aria-label={`اتجاه ${label}`}>
          {([["up", "زاد"], ["down", "نقص"]] as const).map(([v, l]) => (
            <label key={v} className="choice">
              <input type="radio" name={`${id(dirKey)}`} value={v} checked={raw[dirKey] === v} onChange={() => set(dirKey, v)} />
              <span>{l}</span>
            </label>
          ))}
        </div>
        <div className="input-unit">
          <input id={id(k)} type="number" inputMode="decimal" step="any" min={0} max={50} placeholder="0" aria-label={`${label} بالكيلوغرام`}
            value={raw[k]} onChange={(e) => set(k, e.target.value)} aria-invalid={errors[errKey] ? true : undefined} />
          <span aria-hidden="true">كغ</span>
        </div>
      </div>
      <span className="hint">{hint}</span>
      {errors[errKey] && <span className="err-msg">{errors[errKey]}</span>}
    </fieldset>
  );

  const kcalField = (k: "trainingKcal" | "restKcal", label: string) => (
    <div className="field">
      <label htmlFor={id(k)}>{label} <span className="req">*</span></label>
      <div className="input-unit">
        <input id={id(k)} type="number" inputMode="numeric" step="any" min={500} max={10000} value={raw[k]} onChange={(e) => set(k, e.target.value)} aria-invalid={errors[k] ? true : undefined} />
        <span aria-hidden="true">سعرة</span>
      </div>
      {errors[k] && <span className="err-msg">{errors[k]}</span>}
    </div>
  );

  const deficit = result ? result.dailyBalance < 0 : false;

  return (
    <>
      <form className="card form calc-form" onSubmit={onSubmit} noValidate aria-label="حاسبة توازن الطاقة">
        <h2 style={{ fontSize: 22 }}>التغيّر في جسمك</h2>
        <p className="small muted" style={{ marginTop: -8 }}>قارن بين قياسين (مثل فحصي InBody) بينهما 4 أسابيع أو أكثر، واكتب الفرق.</p>
        <div className="grid g2">
          {change("lean", "leanDir", "leanChange", "الكتلة الخالية من الدهون", "في InBody: Lean Body Mass أو «الكتلة الخالية من الدهون» (= الوزن − كتلة الدهون).")}
          {change("fat", "fatDir", "fatChange", "كتلة الدهون", "في InBody: Body Fat Mass أو «كتلة الدهون» بالكيلو، وليس النسبة المئوية.")}
        </div>
        <div className="grid g2">
          <div className="field">
            <label htmlFor={id("startDate")}>تاريخ القياس الأول <span className="req">*</span></label>
            <input id={id("startDate")} type="date" value={raw.startDate} onChange={(e) => set("startDate", e.target.value)} aria-invalid={errors.startDate ? true : undefined} />
            {errors.startDate && <span className="err-msg">{errors.startDate}</span>}
          </div>
          <div className="field">
            <label htmlFor={id("endDate")}>تاريخ القياس الثاني <span className="req">*</span></label>
            <input id={id("endDate")} type="date" value={raw.endDate} onChange={(e) => set("endDate", e.target.value)} aria-invalid={errors.endDate ? true : undefined} />
            {errors.endDate && <span className="err-msg">{errors.endDate}</span>}
          </div>
        </div>

        <h2 style={{ fontSize: 22, marginTop: 8 }}>أكلك خلال نفس الفترة</h2>
        <div className="grid g2">
          {kcalField("trainingKcal", "سعرات يوم التمرين")}
          <div className="field">
            <label htmlFor={id("trainingDays")}>أيام التمرين في الأسبوع <span className="req">*</span></label>
            <select id={id("trainingDays")} value={raw.trainingDays} onChange={(e) => set("trainingDays", e.target.value)}>
              {[0, 1, 2, 3, 4, 5, 6, 7].map((d) => <option key={d} value={d}>{d === 1 ? "يوم واحد" : d === 2 ? "يومين" : `${d} أيام`}</option>)}
            </select>
            <span className="hint">أيام الراحة = الباقي ({7 - (Number(raw.trainingDays) || 0)} {7 - (Number(raw.trainingDays) || 0) === 1 ? "يوم" : "أيام"}).</span>
            {errors.trainingDays && <span className="err-msg">{errors.trainingDays}</span>}
          </div>
          {kcalField("restKcal", "سعرات يوم الراحة")}
        </div>
        <button type="submit" className="btn btn-block">احسب توازن الطاقة</button>
      </form>

      {result && (
        <section id={id("result")} className="card stack calc-result" aria-live="polite" aria-label="النتيجة" style={{ ["--space" as string]: "16px", scrollMarginTop: 90 }}>
          <h2 style={{ fontSize: 22 }}>النتيجة</h2>
          <div className={`calc-target ${deficit ? "is-deficit" : "is-surplus"}`}>
            <span className="muted">توازن الطاقة اليومي</span>
            <b data-testid="calc-daily" dir="ltr">{signed(result.dailyBalance)}</b>
            <span className="small">سعرة يومياً · {deficit ? "عجز" : result.dailyBalance > 0 ? "فائض" : "توازن"} <bdi>{Math.round(Math.abs(result.dailyBalancePct) * 100)}٪</bdi></span>
          </div>
          <div className="grid calc-cards">
            <div className="card flat stat"><span className="muted">سعرات المحافظة الفعلية</span><b data-testid="calc-maintenance">{fmt(result.maintenance)}</b><span className="small muted">سعرة يومياً (تقديرية)</span></div>
            <div className="card flat stat"><span className="muted">متوسط أكلك اليومي</span><b data-testid="calc-avg">{fmt(result.avgIntake)}</b><span className="small muted">سعرة</span></div>
            <div className="card flat stat"><span className="muted">صافي التوازن للفترة</span><b data-testid="calc-net" dir="ltr">{signed(result.netKcal)}</b><span className="small muted">سعرة</span></div>
            <div className="card flat stat"><span className="muted">مدة الفترة</span><b data-testid="calc-days">{result.days}</b><span className="small muted">يوم</span></div>
          </div>
          {result.warnings.map((w) => <p key={w} className="alert warn">{w}</p>)}
          <details className="small">
            <summary style={{ cursor: "pointer", minHeight: 44 }}>كيف حسبناها؟</summary>
            <ul className="calc-steps">
              <li>طاقة الكتلة الخالية من الدهون: التغيّر × 7.6 ميغاجول/كغ = {result.leanMJ.toFixed(1)} ميغاجول</li>
              <li>طاقة الدهون: التغيّر × 39.5 ميغاجول/كغ = {result.fatMJ.toFixed(1)} ميغاجول</li>
              <li>صافي التوازن = المجموع × 238.85 سعرة/ميغاجول = {signed(result.netKcal)} سعرة، ÷ {result.days} يوم = {signed(result.dailyBalance)} يومياً</li>
              <li>سعرات المحافظة الفعلية = متوسط أكلك ({fmt(result.avgIntake)}) − التوازن اليومي</li>
              <li>المعادلة من حاسبة توازن الطاقة لـ Menno Henselmans.</li>
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
