"use client";
import { useState } from "react";
import { addDays, riyadhDate, startPrefRange } from "@/lib/schedule";

const QUICK = [["بعد أسبوع", 7], ["بعد أسبوعين", 14], ["بعد شهر", 30]] as const;

/** «متى تبي تبدأ برنامجك؟»: بأقرب وقت، أو تاريخ من بكرة إلى شهر (حقول start_mode و start_date) */
export default function StartPrefFields({ initial, error, idPrefix = "sp" }: { initial?: string | null; error?: string; idPrefix?: string }) {
  const [mode, setMode] = useState<"asap" | "date">(initial ? "date" : "asap");
  const [date, setDate] = useState(initial ?? "");
  const today = riyadhDate();
  const { min, max } = startPrefRange(today);
  return (
    <fieldset className="field" data-testid="start-pref">
      <legend>متى تبي تبدأ برنامجك؟</legend>
      <div className="choices" role="radiogroup">
        <label className="choice"><input type="radio" name="start_mode" value="asap" checked={mode === "asap"} onChange={() => setMode("asap")} /><span>بأقرب وقت</span></label>
        <label className="choice"><input type="radio" name="start_mode" value="date" checked={mode === "date"} onChange={() => setMode("date")} /><span>في تاريخ أحدده</span></label>
      </div>
      {mode === "date" && (
        <div className="stack" style={{ ["--space" as string]: "8px", marginTop: 8 }}>
          <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
            {QUICK.map(([l, n]) => (
              <button key={n} type="button" className={`btn btn-ghost btn-sm${date === addDays(today, n) ? " on" : ""}`} aria-pressed={date === addDays(today, n)} onClick={() => setDate(addDays(today, n))}>{l}</button>
            ))}
          </div>
          <label htmlFor={`${idPrefix}-date`} className="small">تاريخ البداية</label>
          <input id={`${idPrefix}-date`} name="start_date" type="date" dir="ltr" min={min} max={max} required value={date} onChange={(e) => setDate(e.target.value)}
            data-err="اختر تاريخاً من بكرة إلى شهر من اليوم." aria-invalid={error ? true : undefined} />
        </div>
      )}
      <span className="hint">{mode === "asap"
        ? "نجهّز برنامجك بأولوية ويبدأ اشتراكك من يوم التفعيل."
        : "اشتراكك ومراجعاتك تبدأ من هذا التاريخ، فما تضيع عليك أيام. أبعد موعد: شهر من اليوم."}</span>
      {error && <span className="err-text small" role="alert">{error}</span>}
    </fieldset>
  );
}
