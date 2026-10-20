"use client";
import { createContext, useContext, useMemo, useState } from "react";
import { TAXONOMY_LEVELS, arPart, muscleAr, cascade, resetAfter, splitPipes, type TaxonomyKey } from "@/lib/exercises";

export type PickerExercise = {
  id: string; name: string; equipment: string | null;
  primary_muscle: string; pattern: string | null; sub_pattern: string | null; anatomical_action: string | null; movement_subcategory: string | null;
  secondary_muscles?: string[] | null;
  rehab_category?: string | null;
};

/** قائمة التمارين تُرسل مرة واحدة للمحرر كله (وليس لكل تمرين)، فتبقى صفحة البرنامج خفيفة */
const Ctx = createContext<PickerExercise[]>([]);
export function ExercisesProvider({ exercises, children }: { exercises: PickerExercise[]; children: React.ReactNode }) {
  return <Ctx.Provider value={exercises}>{children}</Ctx.Provider>;
}

/**
 * اختيار التمرين بقوائم متسلسلة (مثل الشيت): القسم (الكل / التمارين التأهيلية والعلاجية) ← الحالة ← العضلة ← نمط الحركة ←
 * النمط الفرعي ← الحركة التشريحية ← التصنيف الفرعي ← التمرين. كل قائمة اختيارية وتضيّق التي بعدها.
 * يرسل exercise_id، أو الاسم المكتوب في حقل البحث. defaultId: التمرين الحالي (عند تعديل تمرين محفوظ) فتظهر قوائمه معبأة.
 */
export default function ExercisePicker({ exercises: own, idPrefix, defaultId }: { exercises?: PickerExercise[]; idPrefix: string; defaultId?: string }) {
  const shared = useContext(Ctx);
  const exercises = own ?? shared;
  const current = useMemo(() => exercises.find((e) => e.id === defaultId), [exercises, defaultId]);
  const [section, setSection] = useState<"" | "rehab">("");
  const [condition, setCondition] = useState("");
  const [chosen, setChosen] = useState<Partial<Record<TaxonomyKey, string>>>(() => current ? { primary_muscle: current.primary_muscle } : {});
  const [exId, setExId] = useState(defaultId ?? "");
  const [secondary, setSecondary] = useState("");

  const rehabConditions = useMemo(() => {
    const m = new Map<string, number>();
    for (const e of exercises) for (const c of splitPipes(e.rehab_category)) m.set(c, (m.get(c) ?? 0) + 1);
    return [...m].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  }, [exercises]);
  const pool = useMemo(() => {
    const base = section !== "rehab" ? exercises : exercises.filter((e) => e.rehab_category && (!condition || splitPipes(e.rehab_category).includes(condition)));
    return secondary ? base.filter((e) => e.secondary_muscles?.includes(secondary)) : base;
  }, [exercises, section, condition, secondary]);
  const secondaryOptions = useMemo(() => {
    const m = new Map<string, number>();
    for (const e of exercises) for (const s of new Set(e.secondary_muscles ?? [])) m.set(s, (m.get(s) ?? 0) + 1);
    return [...m].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  }, [exercises]);
  const exSecondary = useMemo(() => exercises.find((e) => e.id === exId)?.secondary_muscles ?? [], [exercises, exId]);
  const { options, matches } = useMemo(() => cascade(pool, chosen), [pool, chosen]);
  // التمرين الحالي يبقى في القائمة حتى لو ضيّقت التصفية بعيداً عنه
  const list = useMemo(() => {
    const l = [...matches].sort((a, b) => a.name.localeCompare(b.name));
    return current && !l.some((e) => e.id === current.id) ? [current, ...l] : l;
  }, [matches, current]);
  const id = (k: string) => `${idPrefix}-${k}`;
  const pick = (key: TaxonomyKey, value: string) => { setChosen((c) => resetAfter(c, key, value)); setExId(""); };
  const reset = () => { setChosen({}); setExId(""); };

  return (
    <div className="picker" data-testid="exercise-picker">
      <div className="picker-levels">
        <div className="field">
          <label htmlFor={id("section")}>القسم</label>
          <select id={id("section")} value={section} onChange={(e) => { setSection(e.target.value as "" | "rehab"); setCondition(""); reset(); }}>
            <option value="">كل التمارين</option>
            <option value="rehab">التمارين التأهيلية والعلاجية ({exercises.filter((e) => e.rehab_category).length})</option>
          </select>
        </div>
        {section === "rehab" && (
          <div className="field">
            <label htmlFor={id("condition")}>الحالة</label>
            <select id={id("condition")} value={condition} onChange={(e) => { setCondition(e.target.value); reset(); }} dir="auto">
              <option value="">كل الحالات</option>
              {rehabConditions.map(([c, n]) => <option key={c} value={c}>{arPart(c)} ({n})</option>)}
            </select>
          </div>
        )}
        {TAXONOMY_LEVELS.map(({ key, label }, i) => {
          const opts = options[key];
          const disabled = opts.length === 0;
          return (
            <div key={key} className="field">
              <label htmlFor={id(key)}><span className="picker-step">{i + 1}</span> {label}</label>
              <select id={id(key)} value={chosen[key] ?? ""} onChange={(e) => pick(key, e.target.value)} disabled={disabled} dir="auto">
                <option value="">{disabled ? "لا يوجد" : `الكل (${opts.reduce((a, o) => a + o.count, 0)})`}</option>
                {opts.map((o) => <option key={o.value} value={o.value}>{o.value} ({o.count})</option>)}
              </select>
            </div>
          );
        })}
        <div className="field">
          <label htmlFor={id("secondary")}>العضلة الثانوية</label>
          <select id={id("secondary")} value={secondary} onChange={(e) => { setSecondary(e.target.value); setExId(""); }} disabled={secondaryOptions.length === 0}>
            <option value="">الكل</option>
            {secondaryOptions.map(([m, n]) => <option key={m} value={m}>{muscleAr(m)} ({n})</option>)}
          </select>
        </div>
      </div>
      <div className="grid g2">
        <div className="field">
          <label htmlFor={id("ex")}>التمرين ({list.length})</label>
          <select id={id("ex")} name="exercise_id" value={exId} onChange={(e) => setExId(e.target.value)} dir="ltr">
            <option value="">اختاري…</option>
            {list.map((e) => <option key={e.id} value={e.id}>{e.name}{e.equipment ? ` — ${e.equipment}` : ""}</option>)}
          </select>
          {exId && <span className="hint" data-testid="picker-secondary">{(() => { const e = exercises.find((x) => x.id === exId); return e ? `الأساسية: ${muscleAr(e.primary_muscle)} · الثانوية: ${exSecondary.length ? [...new Set(exSecondary)].map(muscleAr).join("، ") : "—"}` : ""; })()}</span>}
        </div>
        <div className="field">
          <label htmlFor={id("name")}>أو ابحثي بالاسم</label>
          <input id={id("name")} name="exercise" type="text" list="ex-options" dir="ltr" autoComplete="off" disabled={!!exId} placeholder={exId ? "تم الاختيار من القائمة" : ""} />
        </div>
      </div>
    </div>
  );
}
