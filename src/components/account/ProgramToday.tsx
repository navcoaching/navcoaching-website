import Link from "next/link";
import type { Tx } from "@/lib/db";
import { currentWeek } from "@/lib/training";
import { sumMacros } from "@/lib/nutrition";
import { loadRoutine, type Routine } from "@/lib/nutrition-data";

export type ProgramToday = {
  block: { name: string; week: number; weeks: number; steps_goal_week: number; days: { id: string; day_no: number; title: string; items: number; logged: number }[] } | null;
  target: { kcal: number | null; protein: number | null; carbs: number | null; fat: number | null; rules: string | null } | null;
  eaten: { kcal: number; protein: number; carbs: number; fat: number };
  plans: { id: string; name: string }[];
  routine: Routine | null;
};

/** ما يحتاجه المتدرب اليوم من اشتراكه: أيام تمرين الأسبوع، أهداف التغذية وما سجّله اليوم، والمكملات */
export async function loadProgramToday(tx: Tx, orderId: string, userId: string, today: string): Promise<ProgramToday> {
  const { rows: [b] } = await tx.query(
    `SELECT id, name, start_date::text AS start_date, weeks, steps_goal_week FROM blocks WHERE order_id = $1 AND status = 'active'`, [orderId]);
  let block: ProgramToday["block"] = null;
  if (b) {
    const week = Math.max(1, currentWeek(b.start_date, today, b.weeks));
    const days = (await tx.query(
      `SELECT d.id, d.day_no, d.title, count(DISTINCT i.id)::int AS items, count(DISTINCT l.block_item_id)::int AS logged
         FROM block_days d LEFT JOIN block_items i ON i.day_id = d.id
         LEFT JOIN item_logs l ON l.block_item_id = i.id AND l.week_no = $2
        WHERE d.block_id = $1 GROUP BY d.id ORDER BY d.day_no`, [b.id, week])).rows;
    block = { name: b.name, week, weeks: b.weeks, steps_goal_week: Number(b.steps_goal_week ?? 0), days };
  }
  const target = (await tx.query(
    `SELECT kcal, protein::float, carbs::float, fat::float, rules FROM nutrition_targets WHERE order_id = $1`, [orderId])).rows[0] ?? null;
  const logs = (await tx.query(
    `SELECT protein::float, carbs::float, fat::float FROM food_logs WHERE order_id = $1 AND user_id = $2 AND log_date = $3`, [orderId, userId, today])).rows;
  const plans = (await tx.query(
    `SELECT id, name FROM nutrition_plans WHERE order_id = $1 AND NOT archived ORDER BY position, created_at`, [orderId])).rows;
  const routine = await loadRoutine(tx, { orderId });
  return { block, target, eaten: sumMacros(logs), plans, routine };
}

const n0 = (v: number) => Math.round(v).toLocaleString("en-US");

export default function ProgramTodayView({ orderNo, p }: { orderNo: string; p: ProgramToday }) {
  const base = `/account/orders/${orderNo}`;
  const hasNutrition = p.target || p.plans.length > 0;
  if (!p.block && !hasNutrition && !p.routine) return null;
  return (
    <div className="program-today stack" style={{ ["--space" as string]: "14px" }} data-testid="program-today">
      {p.block && (
        <section className="stack" style={{ ["--space" as string]: "8px" }} data-testid="today-training">
          <div className="row" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
            <h3 style={{ fontSize: 17 }}>🏋️ برنامجك الحالي</h3>
            <span className="small muted">{p.block.name} · الأسبوع {p.block.week} من {p.block.weeks}</span>
          </div>
          <ul className="today-days">
            {p.block.days.map((d) => {
              const done = d.items > 0 && d.logged >= d.items;
              return (
                <li key={d.id}>
                  <Link href={`${base}/training?week=${p.block!.week}&day=${d.id}`} className={done ? "done" : ""}>
                    <span><b>اليوم {d.day_no}</b> <bdi dir="ltr">{d.title}</bdi></span>
                    <span className="small">{done ? "✅ تم" : `${d.logged} من ${d.items}`}</span>
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {hasNutrition && (
        <section className="stack" style={{ ["--space" as string]: "8px" }} data-testid="today-nutrition">
          <div className="row" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
            <h3 style={{ fontSize: 17 }}>🥗 التغذية اليوم</h3>
            <Link className="small" href={`${base}/nutrition`}>سجّل أكلك ←</Link>
          </div>
          {p.target && (
            <div className="today-macros">
              {([["السعرات", p.eaten.kcal, p.target.kcal, ""], ["بروتين", p.eaten.protein, p.target.protein, "غ"], ["كارب", p.eaten.carbs, p.target.carbs, "غ"], ["دهون", p.eaten.fat, p.target.fat, "غ"]] as const).map(([label, got, goal, unit]) => (
                <div key={label}>
                  <span className="small muted">{label}</span>
                  <b className="num">{n0(got)}{unit && ` ${unit}`}{goal != null && <span className="muted"> من {n0(goal)}{unit && ` ${unit}`}</span>}</b>
                </div>
              ))}
            </div>
          )}
          {p.plans.length > 0 && (
            <p className="small" style={{ margin: 0 }}>جداولك: {p.plans.map((pl, i) => (
              <span key={pl.id}>{i > 0 && "، "}<Link href={`${base}/nutrition?tab=plans`}>{pl.name}</Link></span>
            ))}</p>
          )}
        </section>
      )}

      {p.routine && (
        <section className="stack" style={{ ["--space" as string]: "8px" }} data-testid="today-supplements">
          <div className="row" style={{ justifyContent: "space-between", alignItems: "baseline" }}>
            <h3 style={{ fontSize: 17 }}>💊 روتين المكملات</h3>
            <Link className="small" href={`${base}/nutrition?tab=supplements`}>التفاصيل ←</Link>
          </div>
          {p.routine.sections.filter((s) => s.items.length).map((s) => (
            <div key={s.id} className="small">
              <b>{s.title}</b>
              <ul className="supp-mini">
                {s.items.map((it) => <li key={it.id}><bdi>{it.name}</bdi>{it.timing ? <span className="muted"> — {it.timing}</span> : null}</li>)}
              </ul>
            </div>
          ))}
        </section>
      )}
    </div>
  );
}
