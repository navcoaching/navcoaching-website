"use client";
import { useMemo, useState } from "react";
import { TAXONOMY_LEVELS, cascade, resetAfter, type TaxonomyKey } from "@/lib/exercises";

export type PickerExercise = {
  id: string; name: string; equipment: string | null;
  primary_muscle: string; pattern: string | null; sub_pattern: string | null; anatomical_action: string | null; movement_subcategory: string | null;
};

/**
 * اختيار التمرين بقوائم متسلسلة (مثل الشيت): العضلة ← نمط الحركة ← النمط الفرعي ← الحركة التشريحية ← التصنيف الفرعي ← التمرين.
 * كل قائمة اختيارية وتضيّق التي بعدها. يرسل exercise_id، أو الاسم المكتوب في حقل البحث.
 */
export default function ExercisePicker({ exercises, idPrefix }: { exercises: PickerExercise[]; idPrefix: string }) {
  const [chosen, setChosen] = useState<Partial<Record<TaxonomyKey, string>>>({});
  const [exId, setExId] = useState("");
  const { options, matches } = useMemo(() => cascade(exercises, chosen), [exercises, chosen]);
  const list = useMemo(() => [...matches].sort((a, b) => a.name.localeCompare(b.name)), [matches]);
  const id = (k: string) => `${idPrefix}-${k}`;
  const pick = (key: TaxonomyKey, value: string) => { setChosen((c) => resetAfter(c, key, value)); setExId(""); };

  return (
    <div className="picker" data-testid="exercise-picker">
      <div className="picker-levels">
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
      </div>
      <div className="grid g2">
        <div className="field">
          <label htmlFor={id("ex")}>التمرين ({list.length})</label>
          <select id={id("ex")} name="exercise_id" value={exId} onChange={(e) => setExId(e.target.value)} dir="ltr">
            <option value="">اختاري…</option>
            {list.map((e) => <option key={e.id} value={e.id}>{e.name}{e.equipment ? ` — ${e.equipment}` : ""}</option>)}
          </select>
        </div>
        <div className="field">
          <label htmlFor={id("name")}>أو ابحثي بالاسم</label>
          <input id={id("name")} name="exercise" type="text" list="ex-options" dir="ltr" autoComplete="off" disabled={!!exId} placeholder={exId ? "تم الاختيار من القائمة" : ""} />
        </div>
      </div>
    </div>
  );
}
