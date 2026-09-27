import type { Tx } from "@/lib/db";
import { sumMacros, type MealKind } from "@/lib/nutrition";

export type PlanItem = { id: string; food: string; portion: string | null; protein: number; carbs: number; fat: number };
export type PlanMeal = { id: string; kind: MealKind; title: string; method: string | null; items: PlanItem[]; total: ReturnType<typeof sumMacros> };
export type Plan = { id: string; order_id: string | null; name: string; notes: string | null; archived: boolean; meals: PlanMeal[]; total: ReturnType<typeof sumMacros> };

/** الجداول الغذائية بمكوناتها ومجاميعها. بالمعرّفات، أو كل جداول طلب (orderId)، أو القوالب (orderId = null) */
export async function loadPlans(tx: Tx, where: { ids: string[] } | { orderId: string | null }): Promise<Plan[]> {
  const plans = "ids" in where
    ? (await tx.query(`SELECT id, order_id, name, notes, archived FROM nutrition_plans WHERE id = ANY($1::uuid[]) ORDER BY position, created_at`, [where.ids])).rows
    : (await tx.query(`SELECT id, order_id, name, notes, archived FROM nutrition_plans WHERE order_id IS NOT DISTINCT FROM $1 ORDER BY archived, position, created_at`, [where.orderId])).rows;
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
