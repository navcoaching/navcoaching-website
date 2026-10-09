import type { Tx } from "@/lib/db";
import { sumMacros, type MealKind, type Target } from "@/lib/nutrition";

export type PlanItem = { id: string; food: string; portion: string | null; protein: number; carbs: number; fat: number };
export type PlanMeal = { id: string; kind: MealKind; title: string; method: string | null; items: PlanItem[]; total: ReturnType<typeof sumMacros> };
export type Plan = { id: string; order_id: string | null; source_id: string | null; is_library?: boolean; name: string; notes: string | null; archived: boolean; meals: PlanMeal[]; total: ReturnType<typeof sumMacros> };

/** الجداول الغذائية بمكوناتها ومجاميعها. بالمعرّفات، أو كل جداول طلب (orderId)، أو القوالب (orderId = null) */
export async function loadPlans(tx: Tx, where: { ids: string[] } | { orderId: string | null }): Promise<Plan[]> {
  const plans = "ids" in where
    ? (await tx.query(`SELECT id, order_id, source_id, name, notes, archived, is_library FROM nutrition_plans WHERE id = ANY($1::uuid[]) ORDER BY position, created_at`, [where.ids])).rows
    : (await tx.query(`SELECT id, order_id, source_id, name, notes, archived, is_library FROM nutrition_plans WHERE order_id IS NOT DISTINCT FROM $1 ORDER BY archived, position, created_at`, [where.orderId])).rows;
  if (!plans.length) return [];
  const ids = plans.map((p) => p.id);
  const meals = (await tx.query(`SELECT id, plan_id, kind, title, method FROM plan_meals WHERE plan_id = ANY($1::uuid[]) ORDER BY position, id`, [ids])).rows;
  const items = (await tx.query(
    `SELECT i.id, i.meal_id, i.food, i.portion, i.protein::float, i.carbs::float, i.fat::float
       FROM plan_items i JOIN plan_meals m ON m.id = i.meal_id WHERE m.plan_id = ANY($1::uuid[]) ORDER BY i.position, i.id`, [ids])).rows;
  return plans.map((p) => {
    const pm = meals.filter((m) => m.plan_id === p.id).map((m) => {
      const its = items.filter((i) => i.meal_id === m.id);
      return { ...m, items: its, total: sumMacros(its) } as PlanMeal;
    });
    return { ...p, meals: pm, total: sumMacros(pm.map((m) => m.total)) } as Plan;
  });
}

export type SuppItem = { id: string; name: string; dose: string | null; timing: string | null; importance: string | null; benefit: string | null; link: string | null };
export type Routine = { id: string; order_id: string | null; name: string; intro: string | null; sections: { id: string; title: string; routine: string | null; items: SuppItem[] }[] };

export async function loadRoutine(tx: Tx, where: { id: string } | { orderId: string }): Promise<Routine | null> {
  const { rows: [r] } = "id" in where
    ? await tx.query(`SELECT id, order_id, name, intro FROM supplement_routines WHERE id = $1`, [where.id])
    : await tx.query(`SELECT id, order_id, name, intro FROM supplement_routines WHERE order_id = $1 AND NOT archived`, [where.orderId]);
  if (!r) return null;
  const sections = (await tx.query(`SELECT id, title, routine FROM supplement_sections WHERE routine_id = $1 ORDER BY position, id`, [r.id])).rows;
  const items = (await tx.query(
    `SELECT i.* FROM supplement_items i JOIN supplement_sections s ON s.id = i.section_id WHERE s.routine_id = $1 ORDER BY i.position, i.id`, [r.id])).rows;
  return { ...r, sections: sections.map((s) => ({ ...s, items: items.filter((i) => i.section_id === s.id) })) };
}

export type FoodLog = { id: number; kind: MealKind; name: string; protein: number; carbs: number; fat: number; meal_id: string | null };

/** يوم التغذية للمتدرب: الأهداف، الجداول، المكملات، أكل اليوم، ووجبات المكتبة الجاهزة (للموقع والتطبيق) */
export async function loadNutritionDay(tx: Tx, userId: string, orderNo: string, date: string, withLibrary: boolean) {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, user_id, status FROM orders WHERE order_no = $1`, [orderNo]);
  if (!o || o.user_id !== userId) return null;
  // RLS: الأهداف والجداول والمكملات تظهر لصاحبها بعد تأكيد الدفع فقط
  const target = (await tx.query(`SELECT kcal, protein::float, carbs::float, fat::float, rules FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0] as (Target & { rules: string | null }) | undefined;
  const plans = (await loadPlans(tx, { orderId: o.id })).filter((p) => !p.archived);
  const routine = await loadRoutine(tx, { orderId: o.id });
  // كل وجبات قوالب التغذية (يقدر يضيف أي وجبة منها لأكله اليومي)
  const library = withLibrary && ["active", "delivered", "completed"].includes(o.status)
    ? (await tx.query(`SELECT meal_id::text AS id, plan_name, kind, title, protein::float, carbs::float, fat::float, foods FROM app.library_meals() ORDER BY title`)).rows as { id: string; plan_name: string; kind: MealKind; title: string; protein: number; carbs: number; fat: number; foods: string | null }[]
    : [];
  const logs = (await tx.query(
    `SELECT id::int, kind, name, protein::float, carbs::float, fat::float, meal_id FROM food_logs WHERE user_id = $1 AND order_id = $2 AND log_date = $3 ORDER BY created_at`,
    [userId, o.id, date])).rows as FoodLog[];
  // مكونات وطريقة تحضير الوجبات المسجّلة اليوم (من جداوله أو قوالب التغذية)
  const mealIds = [...new Set(logs.map((l) => l.meal_id).filter((x): x is string => Boolean(x)))];
  const details = mealIds.length
    ? (await tx.query(`SELECT meal_id::text AS id, method, items FROM app.meal_details($1::uuid[])`, [mealIds])).rows as { id: string; method: string | null; items: { food: string; portion: string | null; protein: number; carbs: number; fat: number }[] }[]
    : [];
  return { o, target, plans, routine, logs, library, details };
}
