import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";
import { addDays, riyadhDate } from "@/lib/schedule";
import ActionForm from "@/components/admin/ActionForm";
import { assignNutritionAction, assignSupplementsAction, saveTargetsAction } from "@/app/actions/nutrition";
import { DEFAULT_RULES, sumMacros, targetCheck, type Target } from "@/lib/nutrition";
import { loadPlans, loadRoutine } from "@/lib/nutrition-data";

type Log = { log_date: string; protein: number; carbs: number; fat: number };

/** التغذية والمكملات لمتدرب: الأهداف، جداوله، روتين المكملات، وسجل أكله اليومي */
export default async function OrderNutrition({ params }: { params: Promise<{ orderNo: string }> }) {
  const coach = await requireCoach();
  const { orderNo } = await params;
  const today = riyadhDate();
  const data = await withUser(coach.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, contact_name, product_name, status FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o) return null;
    const target = (await tx.query(`SELECT kcal, protein::float, carbs::float, fat::float, rules, updated_at FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0] as (Target & { rules: string | null; updated_at: string }) | undefined;
    return {
      o, target,
      plans: await loadPlans(tx, { orderId: o.id }),
      templates: (await tx.query(`SELECT id, name FROM nutrition_plans WHERE order_id IS NULL AND NOT archived ORDER BY position, created_at`)).rows as { id: string; name: string }[],
      routine: await loadRoutine(tx, { orderId: o.id }),
      routineTemplates: (await tx.query(`SELECT id, name FROM supplement_routines WHERE order_id IS NULL AND NOT archived ORDER BY created_at`)).rows as { id: string; name: string }[],
      logs: (await tx.query(
        `SELECT log_date::text, protein::float, carbs::float, fat::float FROM food_logs WHERE order_id = $1 AND log_date >= $2 ORDER BY log_date DESC`,
        [o.id, addDays(today, -13)])).rows as Log[],
    };
  });
  if (!data) notFound();
  const { o, target, plans, templates, routine, routineTemplates, logs } = data;
  const check = target ? targetCheck(target) : null;
  const days = [...new Set(logs.map((l) => l.log_date))];
  const entitled = ["active", "delivered", "completed"].includes(o.status);

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1000 }}>
      <nav className="small"><Link href="/admin/orders">الطلبات</Link> / <Link href={`/admin/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / التغذية والمكملات</nav>
      <h1>التغذية والمكملات — {o.contact_name}</h1>
      {!entitled && <p className="alert warn">المتدرب لا يرى هذا القسم حتى تصبح حالة الطلب «نشط» أو «تم التسليم».</p>}

      <section className="card stack" data-testid="targets">
        <h2 style={{ fontSize: 19 }}>الأرقام الغذائية اليومية</h2>
        <ActionForm action={saveTargetsAction} submit="حفظ الأهداف">
          <input type="hidden" name="order_no" value={o.order_no} />
          <div className="grid g4">
            {([["kcal", "السعرات", 1], ["protein", "البروتين (غ)", 0.1], ["carbs", "الكارب (غ)", 0.1], ["fat", "الدهون (غ)", 0.1]] as const).map(([k, l, step]) => (
              <div key={k} className="field"><label htmlFor={`tg-${k}`}>{l}</label>
                <input id={`tg-${k}`} name={k} type="number" inputMode="decimal" step={step} min={0} dir="ltr" defaultValue={target?.[k] ?? ""} /></div>
            ))}
          </div>
          {check && <p className={`small ${check.ok ? "muted" : "err-text"}`} data-testid="target-check">
            {check.ok ? `مطابق: ${check.fromMacros} سعرة من الماكروز.` : `غير مطابق: الماكروز تعطي ${check.fromMacros} سعرة (الفرق ${check.diff > 0 ? "+" : ""}${check.diff}). راجعي الأرقام.`}
          </p>}
          <div className="field"><label htmlFor="tg-rules">قواعد التغذية (تظهر للمتدرب)</label>
            <textarea id="tg-rules" name="rules" rows={5} maxLength={5000} defaultValue={target?.rules ?? DEFAULT_RULES} /></div>
          <span className="hint">نقطة البداية للسعرات من «حاسبة السعرات» في الموقع، ثم تُعدَّل حسب تقدم المتدرب.</span>
        </ActionForm>
      </section>

      <section className="card stack" data-testid="trainee-plans">
        <h2 style={{ fontSize: 19 }}>الجداول الغذائية للمتدرب</h2>
        {plans.length === 0 ? <p className="small muted">لا توجد جداول بعد. أضيفي من القوالب بالأسفل.</p> : (
          <div className="table-wrap">
            <table className="t">
              <thead><tr><th>الجدول</th><th>السعرات</th><th>بروتين</th><th>كارب</th><th>دهون</th><th><span className="sr-only">إجراء</span></th></tr></thead>
              <tbody>{plans.map((p) => (
                <tr key={p.id}>
                  <td><b>{p.name}</b>{p.archived && <> <span className="status muted">مخفي</span></>}</td>
                  <td className="num">{Math.round(p.total.kcal)}</td><td className="num">{p.total.protein}</td><td className="num">{p.total.carbs}</td><td className="num">{p.total.fat}</td>
                  <td><Link className="btn btn-ghost btn-sm" href={`/admin/nutrition/plans/${p.id}`}>تعديل</Link></td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        )}
        <ActionForm action={assignNutritionAction} className="form inline-form" submit="إضافة للمتدرب">
          <input type="hidden" name="order_no" value={o.order_no} />
          <div className="field"><label htmlFor="as-plan">إضافة جدول من القوالب</label>
            <select id="as-plan" name="template" required defaultValue=""><option value="" disabled>اختاري…</option>{templates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></div>
        </ActionForm>
      </section>

      <section className="card stack" data-testid="trainee-supplements">
        <h2 style={{ fontSize: 19 }}>روتين المكملات</h2>
        {routine ? (
          <p className="row" style={{ justifyContent: "space-between" }}>
            <span><b>{routine.name}</b> <span className="small muted">({routine.sections.reduce((a, s) => a + s.items.length, 0)} مكمل)</span></span>
            <Link className="btn btn-ghost btn-sm" href={`/admin/nutrition/supplements/${routine.id}`}>تعديل</Link>
          </p>
        ) : <p className="small muted">لم يُسند روتين بعد.</p>}
        <ActionForm action={assignSupplementsAction} className="form inline-form" submit={routine ? "استبدال الروتين" : "إسناد"}
          confirm={routine ? "سيُستبدل روتين المتدرب الحالي بنسخة جديدة من القالب. متأكدة؟" : undefined}>
          <input type="hidden" name="order_no" value={o.order_no} />
          <div className="field"><label htmlFor="as-supp">{routine ? "استبدال بروتين من القوالب" : "إسناد روتين من القوالب"}</label>
            <select id="as-supp" name="template" required defaultValue=""><option value="" disabled>اختاري…</option>{routineTemplates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></div>
        </ActionForm>
      </section>

      <section className="card stack" data-testid="food-log-review">
        <h2 style={{ fontSize: 19 }}>سجل أكل المتدرب (آخر 14 يوماً)</h2>
        {days.length === 0 ? <p className="small muted">لم يسجّل أكلاً بعد.</p> : (
          <div className="table-wrap">
            <table className="t">
              <thead><tr><th>اليوم</th><th>السعرات</th><th>بروتين</th><th>كارب</th><th>دهون</th><th>التسجيلات</th></tr></thead>
              <tbody>{days.map((d) => {
                const dl = logs.filter((l) => l.log_date === d);
                const t = sumMacros(dl);
                const pct = (v: number, g: number | null | undefined) => (g ? <span className="small muted"> ({Math.round((v / g) * 100)}٪)</span> : null);
                return (
                  <tr key={d}>
                    <td>{fmtDate(d)}</td>
                    <td className="num">{Math.round(t.kcal)}{pct(t.kcal, target?.kcal)}</td>
                    <td className="num">{t.protein}{pct(t.protein, target?.protein)}</td>
                    <td className="num">{t.carbs}{pct(t.carbs, target?.carbs)}</td>
                    <td className="num">{t.fat}{pct(t.fat, target?.fat)}</td>
                    <td className="num">{dl.length}</td>
                  </tr>
                );
              })}</tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
