"use client";
import { useState } from "react";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { deleteFoodLogAction, logFoodAction } from "@/app/actions/nutrition";
import { MEAL_KINDS, type MealKind } from "@/lib/nutrition";

export type MealOption = { id: string; label: string; kind: MealKind; kcal: number };

/** إضافة أكلة لليوم: وجبة من جداولي (محسوبة) أو إدخال حر بالماكروز */
export function FoodLogForm({ orderNo, date, meals }: { orderNo: string; date: string; meals: MealOption[] }) {
  const [mode, setMode] = useState<"plan" | "free">(meals.length ? "plan" : "free");
  const [kind, setKind] = useState<MealKind>("breakfast");
  const { state, onSubmit, pending } = useFormAction(logFoodAction);
  const list = meals.filter((m) => m.kind === kind);
  const others = meals.filter((m) => m.kind !== kind);
  return (
    <form className="form" onSubmit={onSubmit} data-testid="food-log-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="date" value={date} />
      <fieldset className="field">
        <legend>الوجبة</legend>
        <div className="choices">
          {(Object.keys(MEAL_KINDS) as MealKind[]).map((k) => (
            <label key={k} className="choice"><input type="radio" name="kind" value={k} checked={kind === k} onChange={() => setKind(k)} /><span>{MEAL_KINDS[k]}</span></label>
          ))}
        </div>
      </fieldset>
      {meals.length > 0 && (
        <div className="choices" role="radiogroup" aria-label="طريقة الإضافة">
          <label className="choice"><input type="radio" checked={mode === "plan"} onChange={() => setMode("plan")} /><span>من جداولي</span></label>
          <label className="choice"><input type="radio" checked={mode === "free"} onChange={() => setMode("free")} /><span>أكلة أخرى</span></label>
        </div>
      )}
      {mode === "plan" ? (
        <div className="field">
          <label htmlFor="fl-meal">اختر من وجبات جداولك</label>
          <select id="fl-meal" name="meal" required defaultValue="">
            <option value="" disabled>اختر…</option>
            {list.length > 0 && <optgroup label={MEAL_KINDS[kind]}>{list.map((m) => <option key={m.id} value={m.id}>{m.label} — {Math.round(m.kcal)} سعرة</option>)}</optgroup>}
            {others.length > 0 && <optgroup label="وجبات أخرى">{others.map((m) => <option key={m.id} value={m.id}>{m.label} — {Math.round(m.kcal)} سعرة</option>)}</optgroup>}
          </select>
        </div>
      ) : (
        <>
          <div className="field"><label htmlFor="fl-name">اسم الأكلة</label><input id="fl-name" name="name" type="text" maxLength={160} required placeholder="مثال: ساندويتش تونة" /></div>
          <div className="grid g3">
            {([["protein", "بروتين (غ)"], ["carbs", "كارب (غ)"], ["fat", "دهون (غ)"]] as const).map(([k, l]) => (
              <div key={k} className="field"><label htmlFor={`fl-${k}`}>{l}</label><input id={`fl-${k}`} name={k} type="number" inputMode="decimal" step="0.1" min={0} dir="ltr" /></div>
            ))}
          </div>
          <p className="hint" style={{ margin: 0 }}>السعرات تُحسب تلقائياً من الماكروز. اكتب الأرقام من غلاف المنتج أو تطبيق حساب السعرات.</p>
        </>
      )}
      <FormMessage state={state} />
      <div><Submit pending={pending} className="btn btn-sm">إضافة</Submit></div>
    </form>
  );
}

export function DeleteFoodLog({ id, orderNo, name }: { id: number; orderNo: string; name: string }) {
  const { state, onSubmit, pending } = useFormAction(deleteFoodLogAction, () => window.confirm(`حذف «${name}» من اليوم؟`));
  return (
    <form onSubmit={onSubmit} style={{ display: "inline" }}>
      <input type="hidden" name="id" value={id} /><input type="hidden" name="order_no" value={orderNo} />
      <button type="submit" className="btn btn-ghost btn-sm danger" disabled={pending} aria-label={`حذف ${name}`}>حذف</button>
      {state.error && <span className="err-msg">{state.error}</span>}
    </form>
  );
}
