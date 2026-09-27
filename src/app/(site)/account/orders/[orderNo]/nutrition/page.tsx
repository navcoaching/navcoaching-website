import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { fmtDate } from "@/lib/format";
import { addDays, riyadhDate } from "@/lib/schedule";
import { MEAL_ICON, MEAL_KINDS, kcalOf, sumMacros, type MealKind, type Target } from "@/lib/nutrition";
import { loadPlans, loadRoutine } from "@/lib/nutrition-data";
import MacroSummary from "@/components/nutrition/MacroSummary";
import { DeleteFoodLog, FoodLogForm } from "./NutritionForms";

export const metadata: Metadata = { title: "التغذية والمكملات", robots: { index: false } };
type SP = { tab?: string; date?: string };
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
    const logs = (await tx.query(
      `SELECT id::int, kind, name, protein::float, carbs::float, fat::float, meal_id FROM food_logs WHERE user_id = $1 AND order_id = $2 AND log_date = $3 ORDER BY created_at`,
      [user.id, o.id, date])).rows as Log[];
    return { o, target, plans, routine, logs };
  });
  if (!data) notFound();
  const { o, target, plans, routine, logs } = data;
  const base = `/account/orders/${o.order_no}/nutrition`;
  const nothing = !target && plans.length === 0 && !routine;
  const t: Target = target ?? { kcal: null, protein: null, carbs: null, fat: null };
  const total = sumMacros(logs);
  const mealOptions = plans.flatMap((p) => p.meals.map((m) => ({ id: m.id, kind: m.kind, label: `${p.name} — ${m.title}`, kcal: m.total.kcal })));
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
            </nav>

            {tab === "today" && (
              <>
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <Link className="btn btn-ghost btn-sm" href={`${base}?date=${addDays(date, -1)}`}>→ اليوم السابق</Link>
                  <b data-testid="log-date">{date === today ? "اليوم" : fmtDate(date)}</b>
                  {date < today ? <Link className="btn btn-ghost btn-sm" href={`${base}?date=${addDays(date, 1)}`}>اليوم التالي ←</Link> : <span />}
                </div>
                <div className="grid g2" style={{ alignItems: "start" }}>
                  <MacroSummary target={t} total={total} />
                  <section className="card stack" style={{ ["--space" as string]: "10px" }}>
                    <h2 style={{ fontSize: 17 }}>أضف أكلة</h2>
                    <FoodLogForm orderNo={o.order_no} date={date} meals={mealOptions} />
                  </section>
                </div>
                <section className="card stack" style={{ ["--space" as string]: "10px" }} data-testid="food-log-list">
                  <h2 style={{ fontSize: 17 }}>أكل {date === today ? "اليوم" : "هذا اليوم"}</h2>
                  {logs.length === 0 ? <p className="small muted">ما سجّلت شيء بعد.</p> : (Object.keys(MEAL_KINDS) as MealKind[]).map((k) => {
                    const kl = logs.filter((l) => l.kind === k);
                    if (!kl.length) return null;
                    return (
                      <div key={k} className="stack" style={{ ["--space" as string]: "6px" }}>
                        <b>{MEAL_ICON[k]} {MEAL_KINDS[k]}</b>
                        {kl.map((l) => (
                          <div key={l.id} className="row food-log-row" style={{ justifyContent: "space-between" }}>
                            <span>{l.name}<span className="small muted"> · {Math.round(kcalOf(l))} سعرة · ب {f1(l.protein)} · ك {f1(l.carbs)} · د {f1(l.fat)}</span></span>
                            <DeleteFoodLog id={l.id} orderNo={o.order_no} name={l.name} />
                          </div>
                        ))}
                      </div>
                    );
                  })}
                </section>
                {target?.rules && <details className="card"><summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>قواعد التغذية</summary><p style={{ whiteSpace: "pre-wrap", margin: "8px 0 0" }}>{target.rules}</p></details>}
              </>
            )}

            {tab === "plans" && (
              plans.length === 0 ? <p className="card muted">لا توجد جداول غذائية بعد.</p> : plans.map((p) => (
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
                        {it.link && <a className="small" href={it.link} target="_blank" rel="noopener noreferrer">فتح الرابط ↗</a>}
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
