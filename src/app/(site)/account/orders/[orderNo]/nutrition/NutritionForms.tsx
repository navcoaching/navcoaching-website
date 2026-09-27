"use client";
import { useEffect, useState } from "react";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { deleteFoodLogAction, logFoodAction, logFoodGramsAction } from "@/app/actions/nutrition";
import { MEAL_KINDS, scaleFood, type MealKind } from "@/lib/nutrition";

type LocalFood = { id: string; name_ar: string; name_en: string | null; kcal_100: number; protein_100: number; carbs_100: number; fat_100: number; serving_g: number | null; serving_label: string | null };
type ExtFood = { id: string; name: string; brand: string | null; description: string };
type Picked = { source: "food"; f: LocalFood } | { source: "fatsecret"; f: ExtFood };

/** البحث في قاعدة الأكل ثم كتابة الغرامات (الماكروز تُحسب تلقائياً) */
function FoodSearch({ orderNo, date, kind }: { orderNo: string; date: string; kind: MealKind }) {
  const [q, setQ] = useState("");
  const [res, setRes] = useState<{ local: LocalFood[]; external: ExtFood[]; external_enabled?: boolean; external_error?: boolean } | null>(null);
  const [loading, setLoading] = useState(false);
  const [picked, setPicked] = useState<Picked | null>(null);
  const [grams, setGrams] = useState("");
  const { state, onSubmit, pending } = useFormAction(logFoodGramsAction);
  useEffect(() => {
    const t = q.trim();
    if (t.length < 2) { setRes(null); return; }
    const ctl = new AbortController();
    const timer = setTimeout(async () => {
      setLoading(true);
      try {
        const r = await fetch(`/api/foods/search?q=${encodeURIComponent(t)}`, { signal: ctl.signal });
        setRes(r.ok ? await r.json() : { local: [], external: [] });
      } catch { /* أُلغي */ } finally { setLoading(false); }
    }, 300);
    return () => { clearTimeout(timer); ctl.abort(); };
  }, [q]);
  useEffect(() => { if (state.ok) { setPicked(null); setGrams(""); } }, [state]);
  const g = Number(grams.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))));
  const preview = picked?.source === "food" && g > 0 ? scaleFood(picked.f, g) : null;

  if (picked) {
    const name = picked.source === "food" ? picked.f.name_ar : picked.f.brand ? `${picked.f.name} (${picked.f.brand})` : picked.f.name;
    return (
      <form className="form" onSubmit={onSubmit} data-testid="food-grams-form">
        <input type="hidden" name="order_no" value={orderNo} /><input type="hidden" name="date" value={date} />
        <input type="hidden" name="kind" value={kind} /><input type="hidden" name="source" value={picked.source} /><input type="hidden" name="food" value={picked.f.id} />
        <div className="row" style={{ justifyContent: "space-between" }}>
          <b>{name}</b>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setPicked(null)}>تغيير</button>
        </div>
        {picked.source === "food" && <span className="small muted">لكل 100غ: {Math.round(picked.f.kcal_100)} سعرة · ب {picked.f.protein_100} · ك {picked.f.carbs_100} · د {picked.f.fat_100}</span>}
        <div className="field">
          <label htmlFor="fg-grams">الكمية (غرام)</label>
          <input id="fg-grams" name="grams" type="number" inputMode="decimal" step="1" min={1} max={3000} dir="ltr" required value={grams} onChange={(e) => setGrams(e.target.value)} autoFocus />
          {picked.source === "food" && picked.f.serving_g && <span className="hint">الحصة المعتادة: {picked.f.serving_label ?? ""} {picked.f.serving_g}غ</span>}
        </div>
        {preview && <p className="alert info" style={{ margin: 0 }} data-testid="grams-preview"><b>{preview.kcal}</b> سعرة · بروتين {preview.protein}غ · كارب {preview.carbs}غ · دهون {preview.fat}غ</p>}
        <FormMessage state={state} />
        <div><Submit pending={pending} className="btn btn-sm">إضافة</Submit></div>
      </form>
    );
  }
  return (
    <div className="stack" style={{ ["--space" as string]: "8px" }}>
      <FormMessage state={state} />
      <div className="field">
        <label htmlFor="fs-q">ابحث عن أكل</label>
        <input id="fs-q" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="مثال: رز، دجاج، تمر" autoComplete="off" />
      </div>
      {loading && <p className="small muted">جارٍ البحث…</p>}
      {res && !loading && res.local.length === 0 && res.external.length === 0 && <p className="small muted">لا توجد نتائج. جرّب كلمة أخرى أو «أكلة أخرى».</p>}
      {res && (res.local.length > 0 || res.external.length > 0) && (
        <ul className="food-results" data-testid="food-results">
          {res.local.map((f) => (
            <li key={f.id}><button type="button" onClick={() => { setPicked({ source: "food", f }); setGrams(String(f.serving_g ?? 100)); }}>
              <b>{f.name_ar}</b><span className="small muted">{Math.round(f.kcal_100)} سعرة/100غ · ب {f.protein_100} · ك {f.carbs_100} · د {f.fat_100}</span>
            </button></li>
          ))}
          {res.external.map((f) => (
            <li key={`x${f.id}`}><button type="button" onClick={() => { setPicked({ source: "fatsecret", f }); setGrams("100"); }} dir="auto">
              <b>{f.name}{f.brand ? ` (${f.brand})` : ""}</b><span className="small muted" dir="ltr">{f.description}</span>
            </button></li>
          ))}
        </ul>
      )}
      {res?.external && res.external.length > 0 && (
        <a className="small muted" href="https://www.fatsecret.com" target="_blank" rel="noopener noreferrer">Powered by fatsecret</a>
      )}
    </div>
  );
}

export type MealOption = { id: string; label: string; kind: MealKind; kcal: number };

/** إضافة أكلة لليوم: وجبة من جداولي (محسوبة) أو إدخال حر بالماكروز */
export function FoodLogForm({ orderNo, date, meals }: { orderNo: string; date: string; meals: MealOption[] }) {
  const [mode, setMode] = useState<"plan" | "search" | "free">(meals.length ? "plan" : "search");
  const [kind, setKind] = useState<MealKind>("breakfast");
  const { state, onSubmit, pending } = useFormAction(logFoodAction);
  const list = meals.filter((m) => m.kind === kind);
  const others = meals.filter((m) => m.kind !== kind);
  return (
    <div className="form" data-testid="food-log-form">
      <fieldset className="field">
        <legend>الوجبة</legend>
        <div className="choices">
          {(Object.keys(MEAL_KINDS) as MealKind[]).map((k) => (
            <label key={k} className="choice"><input type="radio" name="kind_ui" value={k} checked={kind === k} onChange={() => setKind(k)} /><span>{MEAL_KINDS[k]}</span></label>
          ))}
        </div>
      </fieldset>
      <div className="choices" role="radiogroup" aria-label="طريقة الإضافة">
        {meals.length > 0 && <label className="choice"><input type="radio" name="mode" checked={mode === "plan"} onChange={() => setMode("plan")} /><span>من جداولي</span></label>}
        <label className="choice"><input type="radio" name="mode" checked={mode === "search"} onChange={() => setMode("search")} /><span>ابحث بالغرام</span></label>
        <label className="choice"><input type="radio" name="mode" checked={mode === "free"} onChange={() => setMode("free")} /><span>أكلة أخرى</span></label>
      </div>
      {mode === "search" ? <FoodSearch orderNo={orderNo} date={date} kind={kind} /> : (
      <form className="form" onSubmit={onSubmit}>
      <input type="hidden" name="order_no" value={orderNo} />
      <input type="hidden" name="date" value={date} />
      <input type="hidden" name="kind" value={kind} />
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
      )}
    </div>
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
