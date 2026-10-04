"use client";
import { useEffect, useRef, useState } from "react";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { deleteFoodLogAction, logFoodAction, logFoodGramsAction } from "@/app/actions/nutrition";
import { MEAL_ICON, MEAL_KINDS, scaleFood, type MealKind } from "@/lib/nutrition";

type LocalFood = { id: string; name_ar: string; name_en: string | null; kcal_100: number; protein_100: number; carbs_100: number; fat_100: number; serving_g: number | null; serving_label: string | null };
type ExtFood = { id: string; name: string; brand: string | null; description: string };
type Picked = { source: "food"; f: LocalFood } | { source: "fatsecret"; f: ExtFood };

/** البحث في قاعدة الأكل ثم كتابة الغرامات (الماكروز تُحسب تلقائياً) */
function FoodSearch({ orderNo, date, kind, onDone }: { orderNo: string; date: string; kind: MealKind; onDone?: () => void }) {
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
  useEffect(() => { if (state.ok) { setPicked(null); setGrams(""); setQ(""); onDone?.(); } }, [state]); // eslint-disable-line react-hooks/exhaustive-deps
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
        <label htmlFor="fs-q">بحث</label>
        <input id="fs-q" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="ابحث عن أكل: رز، دجاج، تمر…" autoComplete="off" />
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

export type MealOption = { id: string; label: string; kind: MealKind; kcal: number; protein?: number; carbs?: number; fat?: number; own?: boolean };

/** صف وجبة جاهزة: اسمها وماكروزها فقط (بدون مكونات أو طريقة تحضير)، وزر إضافة */
function MealRow({ m, orderNo, date, kind, onDone }: { m: MealOption; orderNo: string; date: string; kind: MealKind; onDone: () => void }) {
  const { state, onSubmit, pending } = useFormAction(logFoodAction);
  useEffect(() => { if (state.ok) onDone(); }, [state]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <li className="meal-pick">
      <form onSubmit={onSubmit}>
        <input type="hidden" name="order_no" value={orderNo} /><input type="hidden" name="date" value={date} />
        <input type="hidden" name="kind" value={kind} /><input type="hidden" name="meal" value={m.id} />
        <span className="meal-pick-main">
          <b>{m.label}</b>
          <span className="small muted"><span className="meal-kind">{MEAL_ICON[m.kind]} {MEAL_KINDS[m.kind]}</span>{m.own ? " · من جدولي" : ""} · {Math.round(m.kcal)} سعرة{m.protein != null ? ` · ب ${Math.round(m.protein)} ك ${Math.round(m.carbs ?? 0)} د ${Math.round(m.fat ?? 0)}` : ""}</span>
          {state.error && <span className="err-msg">{state.error}</span>}
        </span>
        <button type="submit" className="btn btn-sm" disabled={pending} aria-label={`إضافة ${m.label}`}>{pending ? "…" : "إضافة"}</button>
      </form>
    </li>
  );
}

/** وجبات جاهزة (من قوالب التغذية ومن جداولي): فلتر بنوع الوجبة وبحث بالاسم */
function MealPicker({ meals, orderNo, date, kind, onDone }: { meals: MealOption[]; orderNo: string; date: string; kind: MealKind; onDone: () => void }) {
  const [filter, setFilter] = useState<"all" | MealKind>(kind);
  const [q, setQ] = useState("");
  const list = meals.filter((m) => (filter === "all" || m.kind === filter) && (!q.trim() || m.label.includes(q.trim())));
  return (
    <div className="stack" style={{ ["--space" as string]: "8px" }} data-testid="meal-picker">
      <div className="field"><label htmlFor="mp-q">بحث في الوجبات</label><input id="mp-q" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="اسم الوجبة" autoComplete="off" /></div>
      <div className="choices" role="radiogroup" aria-label="نوع الوجبة">
        {(["all", ...Object.keys(MEAL_KINDS)] as ("all" | MealKind)[]).map((k) => (
          <label key={k} className="choice"><input type="radio" name="mp-kind" checked={filter === k} onChange={() => setFilter(k)} /><span>{k === "all" ? "الكل" : MEAL_KINDS[k]}</span></label>
        ))}
      </div>
      {list.length === 0 ? <p className="small muted">لا توجد وجبات مطابقة.</p> : (
        <ul className="meal-picks">{list.map((m) => <MealRow key={m.id} m={m} orderNo={orderNo} date={date} kind={kind} onDone={onDone} />)}</ul>
      )}
    </div>
  );
}

function QuickAdd({ orderNo, date, kind, onDone }: { orderNo: string; date: string; kind: MealKind; onDone: () => void }) {
  const { state, onSubmit, pending } = useFormAction(logFoodAction);
  useEffect(() => { if (state.ok) onDone(); }, [state]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <form className="form" onSubmit={onSubmit} data-testid="quick-add">
      <input type="hidden" name="order_no" value={orderNo} /><input type="hidden" name="date" value={date} /><input type="hidden" name="kind" value={kind} />
      <div className="field"><label htmlFor="fl-name">اسم الأكلة</label><input id="fl-name" name="name" type="text" maxLength={160} required placeholder="مثال: ساندويتش تونة" /></div>
      <div className="grid g3">
        {([["protein", "بروتين (غ)"], ["carbs", "كارب (غ)"], ["fat", "دهون (غ)"]] as const).map(([k, l]) => (
          <div key={k} className="field"><label htmlFor={`fl-${k}`}>{l}</label><input id={`fl-${k}`} name={k} type="number" inputMode="decimal" step="0.1" min={0} dir="ltr" /></div>
        ))}
      </div>
      <p className="hint" style={{ margin: 0 }}>السعرات تُحسب تلقائياً من الماكروز. اكتب الأرقام من غلاف المنتج أو تطبيق حساب السعرات.</p>
      <FormMessage state={state} />
      <div><Submit pending={pending} className="btn btn-sm">إضافة</Submit></div>
    </form>
  );
}

/** زر «+ إضافة» لقسم وجبة (فطور/غداء…) يفتح نافذة بثلاث طرق: بحث، وجبات جاهزة، أكلة أخرى (مثل MyFitnessPal) */
export function AddFoodSheet({ orderNo, date, kind, meals }: { orderNo: string; date: string; kind: MealKind; meals: MealOption[] }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [open, setOpen] = useState(false);
  const [tab, setTab] = useState<"search" | "meals" | "quick">("search");
  const close = () => ref.current?.close();
  const TABS = [["search", "بحث"], ...(meals.length ? [["meals", "وجبات جاهزة"]] : []), ["quick", "أكلة أخرى"]] as const;
  return (
    <>
      <button type="button" className="btn btn-ghost btn-sm add-food-btn" onClick={() => { setOpen(true); ref.current?.showModal(); }} data-testid={`add-food-${kind}`} aria-haspopup="dialog">+ إضافة أكل</button>
      <dialog ref={ref} className="sheet" onClose={() => setOpen(false)} aria-label={`إضافة إلى ${MEAL_KINDS[kind]}`} onClick={(e) => { if (e.target === e.currentTarget) close(); }}>
        {open && (
          <div className="sheet-box" data-testid="food-log-form">
            <div className="sheet-head">
              <b>{MEAL_ICON[kind]} إضافة إلى {MEAL_KINDS[kind]}</b>
              <button type="button" className="btn btn-ghost btn-sm" onClick={close} aria-label="إغلاق">✕</button>
            </div>
            <div className="sheet-tabs" role="tablist">
              {TABS.map(([k, l]) => <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? "on" : ""} onClick={() => setTab(k as typeof tab)} data-testid={`tab-${k}`}>{l}</button>)}
            </div>
            <div className="sheet-body">
              {tab === "search" && <FoodSearch orderNo={orderNo} date={date} kind={kind} onDone={close} />}
              {tab === "meals" && <MealPicker meals={meals} orderNo={orderNo} date={date} kind={kind} onDone={close} />}
              {tab === "quick" && <QuickAdd orderNo={orderNo} date={date} kind={kind} onDone={close} />}
            </div>
          </div>
        )}
      </dialog>
    </>
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
