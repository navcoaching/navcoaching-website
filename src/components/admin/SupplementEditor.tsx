import ActionForm from "@/components/admin/ActionForm";
import { addSectionAction, addSuppAction, deleteSectionAction, deleteSuppAction, saveSectionAction, saveSuppAction } from "@/app/actions/nutrition";
import { IMPORTANCE } from "@/lib/nutrition";
import type { Routine, SuppItem } from "@/lib/nutrition-data";

function SuppFields({ prefix, v }: { prefix: string; v?: SuppItem }) {
  const t = (k: "name" | "dose" | "timing" | "benefit", l: string, max: number, req = false) => (
    <div className="field"><label htmlFor={`${prefix}-${k}`}>{l}</label>
      <input id={`${prefix}-${k}`} name={k} type="text" maxLength={max} required={req} defaultValue={v?.[k] ?? ""} /></div>
  );
  return (
    <div className="grid g3">
      {t("name", "المكمل", 120, true)}{t("dose", "الجرعة", 120)}{t("timing", "التوقيت", 160)}
      <div className="field"><label htmlFor={`${prefix}-importance`}>الأهمية</label>
        <input id={`${prefix}-importance`} name="importance" type="text" list="supp-importance" maxLength={60} defaultValue={v?.importance ?? ""} /></div>
      {t("benefit", "الفائدة", 1000)}
      <div className="field"><label htmlFor={`${prefix}-link`}>الرابط</label>
        <input id={`${prefix}-link`} name="link" type="url" dir="ltr" maxLength={500} defaultValue={v?.link ?? ""} placeholder="https://" /></div>
    </div>
  );
}

/** محرر روتين المكملات (قالب أو نسخة متدرب) */
export default function SupplementEditor({ routine }: { routine: Routine }) {
  return (
    <div className="stack" style={{ ["--space" as string]: "14px" }}>
      <datalist id="supp-importance">{IMPORTANCE.map((i) => <option key={i} value={i} />)}</datalist>
      {routine.sections.map((sec) => (
        <section key={sec.id} className="card stack" style={{ ["--space" as string]: "12px" }} data-testid="supp-section">
          <h3 style={{ fontSize: 18, margin: 0 }}>{sec.title}</h3>
          {sec.items.map((it) => (
            <details key={it.id} className="card flat">
              <summary style={{ cursor: "pointer", minHeight: 40 }}><b>{it.name}</b> <span className="small muted">{[it.dose, it.timing, it.importance].filter(Boolean).join(" · ")}</span></summary>
              <ActionForm action={saveSuppAction} submit="حفظ">
                <input type="hidden" name="item" value={it.id} />
                <SuppFields prefix={`s-${it.id}`} v={it} />
              </ActionForm>
              <ActionForm action={deleteSuppAction} className="form" submit="حذف المكمل" submitClass="btn btn-ghost btn-sm danger" confirm={`حذف «${it.name}»؟`}>
                <input type="hidden" name="item" value={it.id} />
              </ActionForm>
            </details>
          ))}
          <details>
            <summary className="btn btn-ghost btn-sm">+ إضافة مكمل</summary>
            <ActionForm action={addSuppAction} submit="إضافة" resetOnSuccess>
              <input type="hidden" name="section" value={sec.id} />
              <SuppFields prefix={`n-${sec.id}`} />
            </ActionForm>
          </details>
          <details>
            <summary style={{ cursor: "pointer", minHeight: 40 }}>عنوان القسم ونص الروتين</summary>
            <ActionForm action={saveSectionAction} submit="حفظ القسم">
              <input type="hidden" name="section" value={sec.id} />
              <div className="field"><label htmlFor={`st-${sec.id}`}>العنوان</label><input id={`st-${sec.id}`} name="title" type="text" required maxLength={120} defaultValue={sec.title} /></div>
              <div className="field"><label htmlFor={`sr-${sec.id}`}>الروتين (يظهر تحت المكملات)</label><textarea id={`sr-${sec.id}`} name="routine" maxLength={4000} rows={4} defaultValue={sec.routine ?? ""} /></div>
            </ActionForm>
            <ActionForm action={deleteSectionAction} className="form" submit="حذف القسم" submitClass="btn btn-ghost btn-sm danger" confirm={`حذف قسم «${sec.title}» بكل مكملاته؟`}>
              <input type="hidden" name="section" value={sec.id} />
            </ActionForm>
          </details>
        </section>
      ))}
      <div className="card">
        <ActionForm action={addSectionAction} className="form inline-form" submit="+ إضافة قسم" resetOnSuccess>
          <input type="hidden" name="routine" value={routine.id} />
          <div className="field"><label htmlFor={`ns-${routine.id}`}>عنوان القسم</label><input id={`ns-${routine.id}`} name="title" type="text" required maxLength={120} placeholder="تحسين جودة النوم" /></div>
        </ActionForm>
      </div>
    </div>
  );
}
