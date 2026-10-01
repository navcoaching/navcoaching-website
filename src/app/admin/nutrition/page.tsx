import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import { savePlanAction, saveRoutineAction } from "@/app/actions/nutrition";
import { loadPlans } from "@/lib/nutrition-data";

/** قوالب التغذية والمكملات: تُبنى مرة وتُسند للمتدربين (نسخة لكل متدرب) */
export default async function NutritionLibrary() {
  const coach = await requireCoach();
  const { plans, routines } = await withUser(coach.id, async (tx) => ({
    plans: await loadPlans(tx, { orderId: null }),
    routines: (await tx.query(
      `SELECT r.id, r.name, (SELECT count(*)::int FROM supplement_items i JOIN supplement_sections s ON s.id = i.section_id WHERE s.routine_id = r.id) AS items
         FROM supplement_routines r WHERE r.order_id IS NULL ORDER BY r.created_at`)).rows as { id: string; name: string; items: number }[],
  }));
  const library = plans.find((p) => p.is_library);
  const templates = plans.filter((p) => !p.is_library);
  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <h1>التغذية والمكملات</h1>
      <p className="muted">قوالب تُسند للمتدرب من صفحة طلبه ← «التغذية والمكملات». الإسناد ينسخ القالب، فتعديل نسخة المتدرب لا يغيّر القالب. السعرات تُحسب تلقائياً: بروتين×4 + كارب×4 + دهون×9.</p>

      <section className="card stack">
        <h2 style={{ fontSize: 19 }}>الجداول الغذائية</h2>
        <div className="table-wrap">
          <table className="t" data-testid="nutrition-templates">
            <thead><tr><th>الجدول</th><th>الوجبات</th><th>السعرات</th><th>بروتين</th><th>كارب</th><th>دهون</th><th><span className="sr-only">إجراء</span></th></tr></thead>
            <tbody>
              {templates.length === 0 && <tr><td colSpan={7} className="muted">لا توجد جداول بعد.</td></tr>}
              {templates.map((p) => (
                <tr key={p.id}>
                  <td><b>{p.name}</b>{p.archived && <> <span className="status muted">مؤرشف</span></>}</td>
                  <td className="num">{p.meals.length}</td><td className="num">{Math.round(p.total.kcal)}</td>
                  <td className="num">{p.total.protein}</td><td className="num">{p.total.carbs}</td><td className="num">{p.total.fat}</td>
                  <td><Link className="btn btn-ghost btn-sm" href={`/admin/nutrition/plans/${p.id}`}>فتح</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <ActionForm action={savePlanAction} className="form inline-form" submit="+ جدول جديد">
          <div className="field"><label htmlFor="np-name">اسم الجدول الجديد</label><input id="np-name" name="name" type="text" required maxLength={120} placeholder="الجدول الغذائي 6" /></div>
        </ActionForm>
      </section>

      {library && (
        <section className="card stack" data-testid="meal-library">
          <h2 style={{ fontSize: 19 }}>{library.name}</h2>
          <p className="small muted" style={{ margin: 0 }}>{library.meals.length} وجبة، يختار منها المتدرب في «أضف أكلة ← كل الوجبات» (مع وجبات القوالب الأخرى). ما تُسند كجدول، وما تظهر في «جداول مقترحة». تعديل الوجبة هنا يؤثر على التسجيلات الجديدة فقط.</p>
          <div><Link className="btn btn-ghost btn-sm" href={`/admin/nutrition/plans/${library.id}`}>فتح المكتبة</Link></div>
        </section>
      )}

      <section className="card stack">
        <h2 style={{ fontSize: 19 }}>روتين المكملات</h2>
        <ul className="stack" style={{ ["--space" as string]: "6px", listStyle: "none", padding: 0, margin: 0 }} data-testid="supp-templates">
          {routines.length === 0 && <li className="muted">لا يوجد روتين بعد.</li>}
          {routines.map((r) => <li key={r.id} className="row" style={{ justifyContent: "space-between" }}><span><b>{r.name}</b> <span className="small muted">({r.items} مكمل)</span></span><Link className="btn btn-ghost btn-sm" href={`/admin/nutrition/supplements/${r.id}`}>فتح</Link></li>)}
        </ul>
        <ActionForm action={saveRoutineAction} className="form inline-form" submit="+ روتين جديد">
          <div className="field"><label htmlFor="nr-name">اسم الروتين الجديد</label><input id="nr-name" name="name" type="text" required maxLength={120} /></div>
        </ActionForm>
      </section>
    </div>
  );
}
