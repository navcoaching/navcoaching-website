"use client";
import { useState } from "react";
import Link from "next/link";
import { EB_GOALS, EB_GOALS_EN, MACRO_DEFAULTS, MACRO_LIMITS, PAF_LEVELS, PAF_LEVELS_EN, PROTEIN_LEVELS, calculateIntake, macrosFor, proteinPerKg, validateIntake, validateMacroSettings, type BmrMethod, type IntakeErrors, type IntakeInput, type IntakeResult } from "@/lib/calories";
import { href, type Lang } from "@/lib/lang";
import { CALC } from "./text";

// مستويات النشاط خارج التمرين (عامل النشاط البدني). القيم إرشادية وقابلة للتعديل هنا.
const METHOD_KEYS: BmrMethod[] = ["cunningham", "tenhaaf", "tinsley"];

type Raw = { method: BmrMethod; weight: string; bodyFat: string; heightCm: string; age: string; sex: "" | "male" | "female"; paf: string; minutes: string; trainingDays: string; ebFactor: string };
const EMPTY: Raw = { method: "cunningham", weight: "", bodyFat: "", heightCm: "", age: "", sex: "", paf: "1.0", minutes: "60", trainingDays: "4", ebFactor: "0.8" };
const n = (v: string) => (v.trim() === "" ? NaN : Number(v.replace(",", ".").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))));
const fmt = (v: number) => Math.round(v).toLocaleString("en-US");

export default function IntakeCalculator({ idPrefix = "i", lang = "ar" }: { idPrefix?: string; lang?: Lang }) {
  const u = CALC[lang].intake;
  const METHODS = METHOD_KEYS.map((v, i) => ({ v, t: u.methods[i][0], d: u.methods[i][1] }));
  const PAF = lang === "en" ? PAF_LEVELS_EN : PAF_LEVELS;
  const GOALS = lang === "en" ? EB_GOALS_EN : EB_GOALS;
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
    const errs = validateIntake(input, lang);
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
        <span><b>{label}</b> <span className="small muted num">· {fmt(kcal)} {u.kcal}</span></span>
        <span className="row" style={{ gap: 14, flexWrap: "wrap" }}>
          <span>{u.protein} <b className="num">{m.protein}</b>{u.g}</span>
          <span>{u.carbs} <b className="num">{m.carbs}</b>{u.g}</span>
          <span>{u.fat} <b className="num">{m.fat}</b>{u.g}</span>
        </span>
      </div>
    );
  };

  return (
    <>
      <form className="card form calc-form" onSubmit={onSubmit} noValidate aria-label={u.formAria}>
        <fieldset className="field">
          <legend>{u.method}</legend>
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
          {num("weight", u.weight, u.kg)}
          {raw.method === "cunningham" && num("bodyFat", u.bodyFat, "%", u.bodyFatHint)}
          {raw.method === "tenhaaf" && num("heightCm", u.height, u.cm)}
          {raw.method === "tenhaaf" && num("age", u.age, u.years)}
        </div>
        {raw.method === "tenhaaf" && (
          <fieldset className="field">
            <legend>{u.sex} <span className="req">*</span></legend>
            <div className="choices">
              {([["male", u.male], ["female", u.female]] as const).map(([v, l]) => (
                <label key={v} className="choice"><input type="radio" name={id("sex")} value={v} checked={raw.sex === v} onChange={() => set("sex", v)} /><span>{l}</span></label>
              ))}
            </div>
            {errors.sex && <span className="err-msg">{errors.sex}</span>}
          </fieldset>
        )}

        <div className="grid g2">
          {select("paf", u.paf, PAF)}
          {select("trainingDays", u.trainingDays, [0, 1, 2, 3, 4, 5, 6, 7].map((d) => ({ v: String(d), l: d === 0 ? u.noTraining : d === 1 ? u.oneDay : d === 2 ? u.twoDays : `${d} ${u.days}` })))}
          {td > 0 && num("minutes", u.minutes, u.min)}
          {select("ebFactor", u.goal, GOALS)}
        </div>
        <button type="submit" className="btn btn-block">{u.submit}</button>
      </form>

      {result && (
        <section id={id("result")} className="card stack calc-result" aria-live="polite" aria-label={u.resultAria} style={{ ["--space" as string]: "16px", scrollMarginTop: 90 }}>
          <h2 style={{ fontSize: 22 }}>{u.result}</h2>
          <div className="calc-target">
            <span className="muted">{u.target}</span>
            <b data-testid="intake-target">{fmt(result.target)}</b>
            <span className="small muted">{u.kcalDaily}</span>
          </div>
          <div className="grid calc-cards">
            {td > 0 && <div className="card flat stat"><span className="muted">{u.trainingDay}</span><b data-testid="intake-training-day">{fmt(result.trainingDayTarget)}</b><span className="small muted">{u.kcal}</span></div>}
            {td < 7 && <div className="card flat stat"><span className="muted">{u.restDay}</span><b data-testid="intake-rest-day">{fmt(result.restDayTarget)}</b><span className="small muted">{u.kcal}</span></div>}
            <div className="card flat stat"><span className="muted">{u.maintenance}</span><b data-testid="intake-maintenance">{fmt(result.maintenance)}</b><span className="small muted">{u.kcalPerDay}</span></div>
            <div className="card flat stat"><span className="muted">{u.bmr}</span><b data-testid="intake-bmr">{fmt(result.bmr)}</b><span className="small muted">{u.kcal}</span></div>
          </div>
          <div className="card flat stack" style={{ ["--space" as string]: "10px" }} data-testid="intake-macros">
            <h3 style={{ fontSize: 17, margin: 0 }}>{u.macros}</h3>
            <div className="grid g2">
              <div className="field"><label htmlFor={id("mp")}>{u.proteinLevel}</label>
                <select id={id("mp")} value={mp.p} onChange={(e) => setMp((m) => ({ ...m, p: e.target.value }))}>
                  {PROTEIN_LEVELS.map((o) => <option key={o.v} value={o.v}>{lang === "en" ? o.en : o.l}</option>)}
                </select></div>
              <div className="field"><label htmlFor={id("mf")}>{u.fatPerKg}</label>
                <input id={id("mf")} type="number" inputMode="decimal" step="0.1" min={MACRO_LIMITS.fatPerKg[0]} max={MACRO_LIMITS.fatPerKg[1]} value={mp.f} onChange={(e) => setMp((m) => ({ ...m, f: e.target.value }))} aria-invalid={msErr.fatPerKg ? true : undefined} />
                {msErr.fatPerKg && <span className="err-msg">{msErr.fatPerKg}</span>}</div>
            </div>
            {Object.keys(msErr).length === 0 && (
              <div className="stack" style={{ ["--space" as string]: "8px" }}>
                {macroRow(u.avg, result.target, "macros-avg")}
                {td > 0 && macroRow(u.trainingDay, result.trainingDayTarget, "macros-training")}
                {td < 7 && macroRow(u.restDay, result.restDayTarget, "macros-rest")}
              </div>
            )}
            <span className="hint">{u.macroHint}</span>
          </div>
          <details className="small">
            <summary style={{ cursor: "pointer", minHeight: 44 }}>{u.how}</summary>
            <ul className="calc-steps">
              {result.ffm != null && <li>{u.ffm} {result.ffm.toFixed(1)} {u.kg}</li>}
              <li>{u.bmrLine} ({raw.method === "cunningham" ? "Cunningham 1991" : raw.method === "tinsley" ? "Tinsley 2018" : "Ten Haaf 2014"}): {fmt(result.bmr)} {u.kcal}</li>
              {td > 0 && <li>{u.trainingEE} {fmt(result.trainingEE)} {u.kcal}</li>}
              <li>{u.restEE} {fmt(result.restDayEE)}</li>
              {td > 0 && <li>{u.trainingEEday} {fmt(result.trainingDayEE)}</li>}
              <li>{u.maintLine} {raw.ebFactor}</li>
              <li>{u.macroLine}</li>
              <li>{u.source}</li>
            </ul>
          </details>
          <p className="small muted">{u.startNote1} <Link href={href(lang, "/calculator#energy-balance")}>{u.ebLink}</Link>.</p>
          <div className="alert info calc-cta">
            <span>{u.cta}</span>
            <Link href={href(lang, "/programs")} className="btn btn-sm">{u.programs}</Link>
          </div>
        </section>
      )}
    </>
  );
}
