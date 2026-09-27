import ActionForm from "@/components/admin/ActionForm";
import { addFoodAction, addMealAction, deleteFoodAction, deleteMealAction, moveMealAction, saveFoodAction, saveMealAction } from "@/app/actions/nutrition";
import { MEAL_KINDS, kcalOf } from "@/lib/nutrition";
import type { Plan } from "@/lib/nutrition-data";

const f1 = (v: number) => (Math.round(v * 10) / 10).toString();

function MacroLine({ t }: { t: { kcal: number; protein: number; carbs: number; fat: number } }) {
  return (
    <span className="macro-line">
      <span><b>{Math.round(t.kcal)}</b> سعرة</span><span>بروتين <b>{f1(t.protein)}</b>غ</span><span>كارب <b>{f1(t.carbs)}</b>غ</span><span>دهون <b>{f1(t.fat)}</b>غ</span>
    </span>
  );
}

function FoodFields({ prefix, v }: { prefix: string; v?: { food: string; portion: string | null; protein: number; carbs: number; fat: number } }) {
  const num = (k: "protein" | "carbs" | "fat", l: string) => (
    <div className="field"><label htmlFor={`${prefix}-${k}`}>{l}</label>
      <input id={`${prefix}-${k}`} name={k} type="number" inputMode="decimal" step="0.1" min={0} dir="ltr" defaultValue={v ? v[k] : ""} /></div>
  );
  return (
    <>
      <div className="field"><label htmlFor={`${prefix}-food`}>المكوّن</label><input id={`${prefix}-food`} name="food" type="text" required maxLength={160} defaultValue={v?.food} /></div>
      <div className="field"><label htmlFor={`${prefix}-portion`}>الوزن/الحصة</label><input id={`${prefix}-portion`} name="portion" type="text" maxLength={80} defaultValue={v?.portion ?? ""} placeholder="100غ" /></div>
      {num("protein", "بروتين")}{num("carbs", "كارب")}{num("fat", "دهون")}
    </>
  );
}

/** محرر الجدول الغذائي (قالب أو نسخة متدرب): الوجبات ومكوناتها، والسعرات تُحسب تلقائياً */
export default function NutritionPlanEditor({ plan }: { plan: Plan }) {
  return (
    <div className="stack" style={{ ["--space" as string]: "14px" }}>
      <div className="card row" style={{ justifyContent: "space-between" }} data-testid="plan-total">
        <b>مجموع الجدول</b><MacroLine t={plan.total} />
      </div>
      {plan.meals.map((m, idx) => (
        <section key={m.id} className="card stack meal-card" style={{ ["--space" as string]: "12px" }} data-testid="meal-card">
          <div className="row" style={{ justifyContent: "space-between" }}>
            <h3 style={{ fontSize: 18, margin: 0 }}>{m.title}</h3>
            <MacroLine t={m.total} />
          </div>
          <div className="items">
            {m.items.map((it) => (
              <div key={it.id}>
                <ActionForm action={saveFoodAction} className="form food-row" submit="حفظ" submitClass="btn btn-ghost btn-sm">
                  <input type="hidden" name="item" value={it.id} />
                  <FoodFields prefix={`it-${it.id}`} v={it} />
                </ActionForm>
                <div className="row small muted" style={{ gap: 8 }}>
                  <span>{Math.round(kcalOf(it))} سعرة</span>
                  <ActionForm action={deleteFoodAction} className="form" submit="حذف" submitClass="btn btn-ghost btn-sm danger" confirm={`حذف «${it.food}»؟`}>
                    <input type="hidden" name="item" value={it.id} />
                  </ActionForm>
                </div>
              </div>
            ))}
          </div>
          <details>
            <summary className="btn btn-ghost btn-sm">+ إضافة مكوّن</summary>
            <ActionForm action={addFoodAction} className="form food-row" submit="إضافة" resetOnSuccess>
              <input type="hidden" name="meal" value={m.id} />
              <FoodFields prefix={`new-${m.id}`} />
            </ActionForm>
          </details>
          <details>
            <summary style={{ cursor: "pointer", minHeight: 40 }}>اسم الوجبة ونوعها وطريقة التحضير</summary>
            <ActionForm action={saveMealAction} submit="حفظ الوجبة">
              <input type="hidden" name="meal" value={m.id} />
              <div className="grid g2">
                <div className="field"><label htmlFor={`mk-${m.id}`}>النوع</label>
                  <select id={`mk-${m.id}`} name="kind" defaultValue={m.kind}>{Object.entries(MEAL_KINDS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
                <div className="field"><label htmlFor={`mt-${m.id}`}>الاسم</label><input id={`mt-${m.id}`} name="title" type="text" required maxLength={120} defaultValue={m.title} /></div>
              </div>
              <div className="field"><label htmlFor={`mm-${m.id}`}>طريقة التحضير (اختياري)</label><textarea id={`mm-${m.id}`} name="method" maxLength={3000} rows={3} defaultValue={m.method ?? ""} /></div>
            </ActionForm>
            <div className="row" style={{ gap: 8, marginTop: 8 }}>
              {idx > 0 && <ActionForm action={moveMealAction} className="form" submit="↑ لأعلى" submitClass="btn btn-ghost btn-sm"><input type="hidden" name="meal" value={m.id} /><input type="hidden" name="dir" value="up" /></ActionForm>}
              {idx < plan.meals.length - 1 && <ActionForm action={moveMealAction} className="form" submit="↓ لأسفل" submitClass="btn btn-ghost btn-sm"><input type="hidden" name="meal" value={m.id} /><input type="hidden" name="dir" value="down" /></ActionForm>}
              <ActionForm action={deleteMealAction} className="form" submit="حذف الوجبة" submitClass="btn btn-ghost btn-sm danger" confirm={`حذف «${m.title}» بكل مكوناتها؟`}>
                <input type="hidden" name="meal" value={m.id} />
              </ActionForm>
            </div>
          </details>
        </section>
      ))}
      <div className="card">
        <ActionForm action={addMealAction} className="form inline-form" submit="+ إضافة وجبة" resetOnSuccess>
          <input type="hidden" name="plan" value={plan.id} />
          <div className="field" style={{ maxWidth: 160 }}><label htmlFor={`nk-${plan.id}`}>النوع</label>
            <select id={`nk-${plan.id}`} name="kind" defaultValue="breakfast">{Object.entries(MEAL_KINDS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
          <div className="field"><label htmlFor={`nt-${plan.id}`}>اسم الوجبة</label><input id={`nt-${plan.id}`} name="title" type="text" required maxLength={120} placeholder="الغداء — رز مع دجاج" /></div>
        </ActionForm>
      </div>
    </div>
  );
}
