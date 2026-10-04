import { Fragment } from "react";
import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { fmtDate } from "@/lib/format";
import { addDays, riyadhDate } from "@/lib/schedule";
import { MEAL_ICON, MEAL_KINDS, kcalOf, mealName, sumMacros, type MealKind, type Target } from "@/lib/nutrition";
import { loadPlans, loadRoutine } from "@/lib/nutrition-data";
import DaySummary from "@/components/nutrition/DaySummary";
import { AddFoodSheet, DeleteFoodLog, type MealOption } from "./NutritionForms";

export const metadata: Metadata = { title: "التغذية والمكملات", robots: { index: false } };
type SP = { tab?: string; date?: string; plan?: string };
type Log = { id: number; kind: MealKind; name: string; protein: number; carbs: number; fat: number; meal_id: string | null };

export default async function NutritionPage({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<SP> }) {
  const { orderNo } = await params;
  const sp = await searchParams;
  const user = await requireUser(`/account/orders/${orderNo}/nutrition`);
  const today = riyadhDate();
  const date = sp.date && /^\d{4}-\d{2}-\d{2}$/.test(sp.date) && sp.date <= today && sp.date >= addDays(today, -60) ? sp.date : today;
  const tab = sp.tab === "plans" || sp.tab === "supplements" ? sp.tab : "today";

  const data = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, user_id, status FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o || o.user_id !== user.id) return null;
    // RLS: الأهداف والجداول والمكملات تظهر لصاحبها بعد تأكيد الدفع فقط
    const target = (await tx.query(`SELECT kcal, protein::float, carbs::float, fat::float, rules FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0] as (Target & { rules: string | null }) | undefined;
    const plans = (await loadPlans(tx, { orderId: o.id })).filter((p) => !p.archived);
    const routine = await loadRoutine(tx, { orderId: o.id });
    // كل وجبات قوالب التغذية (يقدر يضيف أي وجبة منها لأكله اليومي)
    const library = tab === "today" && ["active", "delivered", "completed"].includes(o.status)
      ? (await tx.query(`SELECT meal_id::text AS id, plan_name, kind, title, protein::float, carbs::float, fat::float, foods FROM app.library_meals() ORDER BY title`)).rows as { id: string; plan_name: string; kind: MealKind; title: string; protein: number; carbs: number; fat: number; foods: string | null }[]
      : [];
    const logs = (await tx.query(
      `SELECT id::int, kind, name, protein::float, carbs::float, fat::float, meal_id FROM food_logs WHERE user_id = $1 AND order_id = $2 AND log_date = $3 ORDER BY created_at`,
      [user.id, o.id, date])).rows as Log[];
    // مكونات وطريقة تحضير الوجبات المسجّلة اليوم (من جداوله أو قوالب التغذية)
    const mealIds = [...new Set(logs.map((l) => l.meal_id).filter((x): x is string => Boolean(x)))];
    const details = mealIds.length
      ? (await tx.query(`SELECT meal_id::text AS id, method, items FROM app.meal_details($1::uuid[])`, [mealIds])).rows as { id: string; method: string | null; items: { food: string; portion: string | null; protein: number; carbs: number; fat: number }[] }[]
      : [];
    return { o, target, plans, routine, logs, library, details };
  });
  if (!data) notFound();
  const { o, target, plans, routine, logs, library, details } = data;
  const detailOf = new Map(details.map((d) => [d.id, d]));
  // الجدول المعروض: المختار من القائمة، وإلا الأول
  const shownPlan = plans.find((p) => p.id === sp.plan) ?? plans[0];
  const base = `/account/orders/${o.order_no}/nutrition`;
  const nothing = !target && plans.length === 0 && !routine;
  const t: Target = target ?? { kcal: null, protein: null, carbs: null, fat: null };
  const total = sumMacros(logs);
  // وجبات جاهزة: من جداولي ثم من قوالب التغذية (اسم الوجبة وماكروزها فقط)
  const ownMeals: MealOption[] = plans.flatMap((p) => p.meals.map((m) => ({ id: m.id, kind: m.kind, label: mealName(m.kind, m.title, m.items.map((it) => it.food).join("، ")), kcal: m.total.kcal, protein: m.total.protein, carbs: m.total.carbs, fat: m.total.fat, own: true })));
  const seen = new Set(ownMeals.map((m) => m.id));
  const readyMeals: MealOption[] = [...ownMeals, ...library.filter((m) => !seen.has(m.id)).map((m) => ({ id: m.id, kind: m.kind, label: mealName(m.kind, m.title, m.foods), kcal: kcalOf(m), protein: m.protein, carbs: m.carbs, fat: m.fat }))];
  const f1 = (v: number) => Math.round(v * 10) / 10;

  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <Link href={`/account/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / التغذية والمكملات</nav>
        <h1 style={{ fontSize: "clamp(24px,4vw,32px)" }}>التغذية والمكملات</h1>
        {nothing ? <p className="card muted">لم تُجهَّز تغذيتك على الموقع بعد. تظهر هنا بعد ما تضيفها المدربة.</p> : (
          <>
            <nav className="tabs" aria-label="أقسام التغذية">
              <Link href={`${base}?tab=today`} aria-current={tab === "today" ? "true" : undefined}>يومي</Link>
              <Link href={`${base}?tab=plans`} aria-current={tab === "plans" ? "true" : undefined}>جداولي الغذائية</Link>
              {routine && <Link href={`${base}?tab=supplements`} aria-current={tab === "supplements" ? "true" : undefined}>المكملات</Link>}
              <Link href={`${base}/log`}>سجل الماكروز</Link>
              <Link href={`${base}/foods`}>دليل مصادر الأكل</Link>
            </nav>

            {tab === "today" && (
              <>
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <Link className="btn btn-ghost btn-sm" href={`${base}?date=${addDays(date, -1)}`}>→ اليوم السابق</Link>
                  <b data-testid="log-date">{date === today ? "اليوم" : fmtDate(date)}</b>
                  {date < today ? <Link className="btn btn-ghost btn-sm" href={`${base}?date=${addDays(date, 1)}`}>اليوم التالي ←</Link> : <span />}
                </div>
                <DaySummary target={t} total={total} />
                <div className="stack" style={{ ["--space" as string]: "12px" }} data-testid="food-log-list">
                  {(Object.keys(MEAL_KINDS) as MealKind[]).map((k) => {
                    const kl = logs.filter((l) => l.kind === k);
                    const kc = Math.round(kl.reduce((a, l) => a + kcalOf(l), 0));
                    return (
                      <section key={k} className="card meal-section" aria-label={MEAL_KINDS[k]} data-testid={`meal-${k}`}>
                        <header className="meal-head">
                          <h2>{MEAL_ICON[k]} {MEAL_KINDS[k]}</h2>
                          <span className="small muted num">{kc} سعرة</span>
                        </header>
                        {kl.length > 0 && (
                          <div className="table-wrap">
                            <table className="meal-table">
                              <thead><tr><th scope="col">الصنف</th><th scope="col">سعرات</th><th scope="col">كارب</th><th scope="col">دهون</th><th scope="col">بروتين</th><th scope="col"><span className="sr-only">حذف</span></th></tr></thead>
                              <tbody>
                                {kl.map((l) => {
                                  const d = l.meal_id ? detailOf.get(l.meal_id) : undefined;
                                  const name = l.meal_id ? mealName(l.kind, l.name, (d?.items ?? []).map((it) => it.food).join("، ")) : l.name;
                                  return (
                                    <Fragment key={l.id}>
                                      <tr className="food-log-row">
                                        <th scope="row" className="mt-name">{name}</th>
                                        <td className="num">{Math.round(kcalOf(l))}</td><td className="num">{f1(l.carbs)}</td><td className="num">{f1(l.fat)}</td><td className="num">{f1(l.protein)}</td>
                                        <td className="mt-del"><DeleteFoodLog id={l.id} orderNo={o.order_no} name={l.name} /></td>
                                      </tr>
                                      {d && (d.items.length > 0 || d.method) && (
                                        <tr className="mt-recipe"><td colSpan={6}>
                                          <details className="meal-more small" data-testid="meal-details">
                                            <summary>المكونات وطريقة التحضير</summary>
                                            <div className="rec">
                                              {d.items.length > 0 && (<><h3>المكونات</h3><ul className="meal-ingredients">{d.items.map((it, i) => <li key={i}>{it.food}{it.portion ? <span className="muted"> — {it.portion}</span> : null}</li>)}</ul></>)}
                                              {d.method && (<><h3>طريقة التحضير</h3><p className="meal-method">{d.method}</p></>)}
                                            </div>
                                          </details>
                                        </td></tr>
                                      )}
                                    </Fragment>
                                  );
                                })}
                                <tr className="mt-total"><th scope="row">إجمالي {MEAL_KINDS[k]}</th><td className="num">{kc}</td><td className="num">{f1(kl.reduce((a, l) => a + l.carbs, 0))}</td><td className="num">{f1(kl.reduce((a, l) => a + l.fat, 0))}</td><td className="num">{f1(kl.reduce((a, l) => a + l.protein, 0))}</td><td /></tr>
                              </tbody>
                            </table>
                          </div>
                        )}
                        <AddFoodSheet orderNo={o.order_no} date={date} kind={k} meals={readyMeals} />
                      </section>
                    );
                  })}
                </div>
                {target?.rules && <details className="card"><summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>قواعد التغذية</summary><p style={{ whiteSpace: "pre-wrap", margin: "8px 0 0" }}>{target.rules}</p></details>}
              </>
            )}

            {tab === "plans" && plans.length > 1 && (
              <nav className="plan-picker" aria-label="اختر جدولك الغذائي" data-testid="plan-picker">
                <p className="small muted" style={{ margin: 0 }}>عندك {plans.length} جداول، اختر اللي يناسبك:</p>
                <div className="plan-options">
                  {plans.map((p) => (
                    <Link key={p.id} href={`${base}?tab=plans&plan=${p.id}`} className={`card plan-option${p.id === shownPlan?.id ? " on" : ""}`}
                      aria-current={p.id === shownPlan?.id ? "true" : undefined}>
                      <b>{p.name}</b>
                      <span className="small muted num">{Math.round(p.total.kcal).toLocaleString("en-US")} سعرة · ب {f1(p.total.protein)} · ك {f1(p.total.carbs)} · د {f1(p.total.fat)}</span>
                    </Link>
                  ))}
                </div>
              </nav>
            )}
            {tab === "plans" && (
              plans.length === 0 ? <p className="card muted">لا توجد جداول غذائية بعد.</p> : (shownPlan ? [shownPlan] : []).map((p) => (
                <section key={p.id} className="stack" style={{ ["--space" as string]: "10px" }} data-testid="my-plan">
                  <h2 style={{ fontSize: 20 }}>{p.name} <span className="small muted">— {Math.round(p.total.kcal)} سعرة · ب {f1(p.total.protein)} · ك {f1(p.total.carbs)} · د {f1(p.total.fat)}</span></h2>
                  {p.notes && <p className="alert info" style={{ whiteSpace: "pre-wrap" }}>{p.notes}</p>}
                  {p.meals.map((m) => (
                    <article key={m.id} className="card stack" style={{ ["--space" as string]: "8px" }}>
                      <h3 style={{ fontSize: 17, margin: 0 }}>{MEAL_ICON[m.kind]} {m.title} <span className="small muted">— {Math.round(m.total.kcal)} سعرة</span></h3>
                      <div className="table-wrap">
                        <table className="t food-table">
                          <thead><tr><th>المكوّن</th><th>الكمية</th><th>السعرات</th><th>بروتين</th><th>كارب</th><th>دهون</th></tr></thead>
                          <tbody>
                            {m.items.map((it) => <tr key={it.id}><td>{it.food}</td><td>{it.portion ?? "—"}</td><td className="num">{Math.round(kcalOf(it))}</td><td className="num">{f1(it.protein)}</td><td className="num">{f1(it.carbs)}</td><td className="num">{f1(it.fat)}</td></tr>)}
                            <tr><th scope="row">الإجمالي</th><td /><td className="num"><b>{Math.round(m.total.kcal)}</b></td><td className="num"><b>{m.total.protein}</b></td><td className="num"><b>{m.total.carbs}</b></td><td className="num"><b>{m.total.fat}</b></td></tr>
                          </tbody>
                        </table>
                      </div>
                      {m.method && <details className="small"><summary style={{ cursor: "pointer", minHeight: 36 }}>طريقة التحضير</summary><p style={{ whiteSpace: "pre-wrap", margin: "6px 0 0" }}>{m.method}</p></details>}
                    </article>
                  ))}
                </section>
              ))
            )}

            {tab === "supplements" && routine && (
              <div className="stack" style={{ ["--space" as string]: "14px" }} data-testid="my-supplements">
                <h2 style={{ fontSize: 20 }}>{routine.name}</h2>
                {routine.intro && <p className="alert info">{routine.intro}</p>}
                {routine.sections.map((s) => (
                  <section key={s.id} className="card stack" style={{ ["--space" as string]: "10px" }}>
                    <h3 style={{ fontSize: 18, margin: 0 }}>{s.title}</h3>
                    {s.items.map((it) => (
                      <div key={it.id} className="card flat stack" style={{ ["--space" as string]: "4px" }}>
                        <div className="row" style={{ justifyContent: "space-between" }}>
                          <b>{it.name}</b>
                          {it.importance && <span className={`status ${it.importance === "مهم جداً" ? "ok" : "muted"}`}>{it.importance}</span>}
                        </div>
                        <span className="small">{[it.dose && `الجرعة: ${it.dose}`, it.timing && `التوقيت: ${it.timing}`].filter(Boolean).join(" · ")}</span>
                        {it.benefit && <span className="small muted">{it.benefit}</span>}
                        {it.link && <a className="small supp-link" href={it.link} target="_blank" rel="noopener noreferrer">فتح الرابط ↗</a>}
                      </div>
                    ))}
                    {s.routine && <p className="small" style={{ whiteSpace: "pre-wrap", margin: 0 }}>{s.routine}</p>}
                  </section>
                ))}
                <p className="small muted">المكملات مساندة فقط، والأساس النوم والتغذية والالتزام بالتمرين. راجع الطبيب قبل أي مكمل إذا عندك حالة صحية أو تستخدم أدوية.</p>
              </div>
            )}
          </>
        )}
      </div>
    </section>
  );
}
