"use client";
import { useActionState } from "react";
import { Submit } from "@/components/FormBits";
import { importTemplateAction, type ImportState } from "@/app/actions/training";

const HOW = { alias: ["من ربط سابق", "ok"], name: ["مطابق", "ok"] } as const;

/** رفع الملف أو لصقه، ثم (إذا في أسماء غير موجودة في المكتبة) مراجعة الأسماء واختيار التمرين لكل اسم */
export default function ImportForm() {
  const [state, action, pending] = useActionState<ImportState, FormData>(importTemplateAction, {});
  const review = state.review;
  const err = state.error && <p className="alert err" role="alert">{state.error}</p>;

  if (review) {
    const open = review.rows.filter((r) => !r.id).length;
    return (
      <form action={action} className="form import-form" data-testid="import-review">
        <input type="hidden" name="text" value={review.text} />
        <input type="hidden" name="confirm" value="1" />
        <p><b>{review.summary}</b></p>
        <p className="small muted">
          {open} {open === 1 ? "اسم غير موجود" : "أسماء غير موجودة"} في مكتبتك بنفس الاسم. اختاري التمرين المقابل لكل اسم (الأقرب أولاً) أو «تجاهل».
          اختياراتك تُحفظ، فيطابق الاسم نفسه تلقائياً في الملفات القادمة. وصف الاسم (مثل «الظهر مائل للخلف») يبقى في ملاحظة التمرين.
        </p>
        {review.rows.map((r, i) => (
          <div key={r.key} className={`field import-name${r.id ? "" : " open"}`}>
            <input type="hidden" name={`k_${i}`} value={r.key} />
            <label htmlFor={`m-${i}`}>
              <bdi dir="ltr">{r.name}</bdi>{" "}
              {r.how ? <span className={`status ${HOW[r.how][1]}`}>{HOW[r.how][0]}</span> : <span className="status action">اختاري</span>}
            </label>
            <select id={`m-${i}`} name={`m_${i}`} defaultValue={r.id ?? ""} required dir="ltr">
              <option value="" disabled>اختاري التمرين…</option>
              {r.suggestions.length > 0 && (
                <optgroup label="الأقرب">{r.suggestions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</optgroup>
              )}
              <optgroup label="كل المكتبة">{review.library.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}</optgroup>
              <option value="skip">تجاهل هذا التمرين</option>
            </select>
          </div>
        ))}
        {err}
        <div className="row" style={{ gap: 10 }}>
          <Submit className="btn btn-sm" pending={pending} pendingText="جارٍ الإنشاء…">إنشاء القالب</Submit>
          <a className="btn btn-ghost btn-sm" href="/admin/templates/import">ملف آخر</a>
        </div>
      </form>
    );
  }

  return (
    <form action={action} className="form import-form">
      <div className="field"><label htmlFor="imp-file">الملف (‎.md‎)</label>
        <input id="imp-file" name="file" type="file" accept=".md,.markdown,.txt,text/markdown,text/plain" data-testid="import-file" /></div>
      <div className="field"><label htmlFor="imp-text">أو الصقي النص</label>
        <textarea id="imp-text" name="text" rows={10} maxLength={200000} dir="ltr" placeholder={"# اسم القالب\n- الأسابيع: 5\n- المكان: النادي\n\n## اليوم 1: UPPER\n| التمرين | الأسبوع 1 | … |"} /></div>
      {err}
      <div><Submit className="btn btn-sm" pending={pending} pendingText="جارٍ القراءة…">استيراد</Submit></div>
    </form>
  );
}
