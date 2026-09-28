import "server-only";
import type { Tx } from "./db";
import { currentWeight, missingFor, profileFromIntake, suggestTargets, type CalorieProfile, type Suggestion, type Target } from "./calorie-suggest.ts";

export type CalorieState = {
  profile: CalorieProfile; stored: boolean; missing: string[];
  weight: { kg: number; source: "logs" | "intake" } | null;
  target: Target | null; suggestion: Suggestion | null;
};

const num = (v: unknown) => (v == null ? null : Number(v));

/** بيانات حساب السعرات لطلب: الملف المحفوظ (أو المبدئي من الاستبيان)، الوزن الحالي، الهدف، والاقتراح */
export async function loadCalorieState(tx: Tx, orderId: string, userId: string): Promise<CalorieState> {
  const { rows: [row] } = await tx.query(
    `SELECT method, sex, age, height_cm::float, body_fat::float, paf::float, training_days, minutes, eb_factor::float, dismissed_kcal
       FROM calorie_profiles WHERE order_id = $1`, [orderId]);
  const { rows: [intake] } = await tx.query(`SELECT answers, health FROM intakes WHERE order_id = $1`, [orderId]);
  const profile: CalorieProfile = row
    ? { ...row, age: num(row.age), height_cm: num(row.height_cm), body_fat: num(row.body_fat) }
    : profileFromIntake(intake?.answers, intake?.health);
  const logs = (await tx.query(
    `SELECT logged_on::text, kg::float FROM weight_logs WHERE user_id = $1 AND logged_on >= current_date - 60 ORDER BY logged_on`, [userId])).rows;
  const weight = currentWeight(logs, num(intake?.health?.weight));
  const target = ((await tx.query(`SELECT kcal, protein::float, carbs::float, fat::float FROM nutrition_targets WHERE order_id = $1`, [orderId])).rows[0] ?? null) as Target | null;
  return { profile, stored: Boolean(row), missing: missingFor(profile), weight, target, suggestion: suggestTargets(profile, weight, target) };
}

/** اقتراحات السعرات المفتوحة لكل المتدربين النشطين الذين لهم أهداف (للوحة الإدارة والإيميل اليومي) */
export async function loadPendingSuggestions(tx: Tx): Promise<{ order_no: string; name: string; kcal: number; diff: number }[]> {
  const orders = (await tx.query(
    `SELECT o.id, o.order_no, o.user_id, o.contact_name FROM orders o JOIN nutrition_targets t ON t.order_id = o.id
      WHERE o.status = 'active' AND o.category = 'follow' AND NOT o.is_demo AND t.kcal IS NOT NULL ORDER BY o.contact_name`)).rows;
  const out = [];
  for (const o of orders) {
    const s = await loadCalorieState(tx, o.id, o.user_id);
    if (s.suggestion && s.suggestion.diff != null) out.push({ order_no: o.order_no, name: String(o.contact_name ?? ""), kcal: s.suggestion.kcal, diff: s.suggestion.diff });
  }
  return out;
}
