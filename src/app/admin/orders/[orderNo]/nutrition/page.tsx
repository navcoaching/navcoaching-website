import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate } from "@/lib/format";
import { addDays, riyadhDate } from "@/lib/schedule";
import ActionForm from "@/components/admin/ActionForm";
import { assignNutritionAction, assignSupplementsAction, saveTargetsAction } from "@/app/actions/nutrition";
import { DEFAULT_RULES, plansNear, sumMacros, targetCheck, type Target } from "@/lib/nutrition";
import { loadPlans, loadRoutine } from "@/lib/nutrition-data";
import { autoFillTargets, loadCalorieState } from "@/lib/calorie-data";
import CalorieSuggest from "@/components/admin/CalorieSuggest";

type Log = { log_date: string; protein: number; carbs: number; fat: number };

/** التغذية والمكملات لمتدرب: الأهداف، جداوله، روتين المكملات، وسجل أكله اليومي */
export default async function OrderNutrition({ params }: { params: Promise<{ orderNo: string }> }) {
  const coach = await requireCoach();
  const { orderNo } = await params;
  const today = riyadhDate();
  const data = await withUser(coach.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, user_id, contact_name, product_name, status FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o) return null;
    await autoFillTargets(tx, o.id);
    const target = (await tx.query(`SELECT kcal, protein::float, carbs::float, fat::float, rules, updated_at FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0] as (Target & { rules: string | null; updated_at: string }) | undefined;
    return {
      o, target, cal: await loadCalorieState(tx, o.id, o.user_id),
      plans: await loadPlans(tx, { orderId: o.id }),
      templates: (await loadPlans(tx, { orderId: null })).filter((t) => !t.archived),
      routine: await loadRoutine(tx, { orderId: o.id }),
      routineTemplates: (await tx.query(`SELECT id, name FROM supplement_routines WHERE order_id IS NULL AND NOT archived ORDER BY created_at`)).rows as { id: string; name: string }[],
      logs: (await tx.query(
        `SELECT log_date::text, protein::float, carbs::float, fat::float FROM food_logs WHERE order_id = $1 AND log_date >= $2 ORDER BY log_date DESC`,
        [o.id, addDays(today, -13)])).rows as Log[],
    };
  });
  if (!data) notFound();
  const { o, target, cal, plans, templates, routine, routineTemplates, logs } = data;
  const check = target ? targetCheck(target) : null;
  const days = [...new Set(logs.map((l) => l.log_date))];
  const entitled = ["active", "delivered", "completed"].includes(o.status);
  const near = plansNear(templates, target?.kcal);
  const added = new Set(plans.filter((p) => !p.archived).map((p) => p.source_id));

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

      <CalorieSuggest orderNo={o.order_no} st={cal} />

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
        <div className="stack" style={{ ["--space" as string]: "8px" }} data-testid="near-plans">
          <h3 style={{ fontSize: 16, margin: 0 }}>جداول مقترحة حسب سعراته{target?.kcal ? <> (<span className="num">{target.kcal.toLocaleString("en-US")}</span> ± 200)</> : ""}</h3>
          {!target?.kcal ? <p className="small muted" style={{ margin: 0 }}>تظهر الاقتراحات بعد تحديد هدف السعرات.</p>
            : near.length === 0 ? <p className="small muted" style={{ margin: 0 }}>ما فيه قالب بفرق 200 سعرة أو أقل. أضيفي من القائمة بالأسفل أو جهّزي قالباً جديداً.</p> : (
            <ul className="stack" style={{ ["--space" as string]: "6px", listStyle: "none", margin: 0, padding: 0 }}>
              {near.map((t) => (
                <li key={t.id} className="row" style={{ justifyContent: "space-between", gap: 8, flexWrap: "wrap" }} data-testid="near-plan">
                  <span>
                    <b>{t.name}</b>{" "}
                    <span className="small muted num" style={{ display: "inline-flex", flexWrap: "wrap", columnGap: 8 }}>
                      <span style={{ whiteSpace: "nowrap" }}>{Math.round(t.total.kcal).toLocaleString("en-US")} سعرة (<bdi dir="ltr">{t.diff > 0 ? "+" : ""}{t.diff}</bdi>)</span>
                      <span style={{ whiteSpace: "nowrap" }}>ب {t.total.protein}</span><span style={{ whiteSpace: "nowrap" }}>ك {t.total.carbs}</span><span style={{ whiteSpace: "nowrap" }}>د {t.total.fat}</span>
                    </span>
                    {t.close && <> <span className="status ok">قريب جداً</span></>}
                  </span>
                  {added.has(t.id) ? <span className="status ok">✓ مضاف له</span> : (
                    <ActionForm action={assignNutritionAction} submit="إضافة للمتدرب" submitClass="btn btn-ghost btn-sm">
                      <input type="hidden" name="order_no" value={o.order_no} />
                      <input type="hidden" name="template" value={t.id} />
                    </ActionForm>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>
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
