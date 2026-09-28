import "server-only";
import type { Tx } from "./db";
import { currentWeight, missingFor, profileFromIntake, suggestTargets, targetKcal, type CalorieProfile, type Suggestion, type Target } from "./calorie-suggest.ts";
import { NUTRITION_SKUS } from "./intake.ts";

export type CalorieState = {
  profile: CalorieProfile; stored: boolean; missing: string[];
  weight: { kg: number; source: "logs" | "intake" } | null;
  target: Target | null; suggestion: Suggestion | null;
  /** السعرات محسوبة تلقائياً ولم تؤكدها المدربة بعد */
  pendingAuto: boolean;
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
  const t = (await tx.query(
    `SELECT kcal, protein::float, carbs::float, fat::float, kcal_source, kcal_confirmed_at FROM nutrition_targets WHERE order_id = $1`, [orderId])).rows[0];
  const target: Target | null = t ? { kcal: t.kcal, protein: t.protein, carbs: t.carbs, fat: t.fat } : null;
  const pendingAuto = Boolean(t && t.kcal != null && t.kcal_source === "auto" && !t.kcal_confirmed_at);
  return {
    profile, stored: Boolean(row), missing: missingFor(profile), weight, target, pendingAuto,
    // وهي بانتظار التأكيد تتحدث الحسبة نفسها تلقائياً، فلا حاجة لاقتراح منفصل
    suggestion: pendingAuto ? null : suggestTargets(profile, weight, target),
  };
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

/**
 * السعرات التلقائية: لكل متدرب في باقة فيها تغذية (قيد الإعداد أو نشط) وليس له هدف سعرات،
 * يُحسب الهدف بحاسبة الموقع ويُحفظ بعلامة «تلقائي» حتى تؤكده المدربة. وما دام غير مؤكد يتحدث مع بيانات المتدرب.
 * البروتين والكارب والدهون لا تُعبّأ تلقائياً. orderId لطلب واحد (صفحة التغذية)، وبدونه كل الطلبات.
 */
export async function autoFillTargets(tx: Tx, orderId?: string): Promise<number> {
  const { rows } = await tx.query(
    `SELECT o.id, o.user_id, t.kcal FROM orders o
       JOIN product_offers po ON po.id = o.offer_id
       LEFT JOIN nutrition_targets t ON t.order_id = o.id
      WHERE o.status IN ('preparing', 'active') AND o.category = 'follow' AND NOT o.is_demo AND po.sku = ANY($1)
        AND (t.kcal IS NULL OR (t.kcal_source = 'auto' AND t.kcal_confirmed_at IS NULL))
        AND ($2::uuid IS NULL OR o.id = $2)`, [NUTRITION_SKUS, orderId ?? null]);
  let n = 0;
  for (const o of rows) {
    const st = await loadCalorieState(tx, o.id, o.user_id);
    const kcal = st.weight ? targetKcal(st.profile, st.weight.kg) : null;
    if (kcal == null || kcal === o.kcal || kcal < 500 || kcal > 10000) continue;
    const r = await tx.query(
      `INSERT INTO nutrition_targets (order_id, kcal, kcal_source) VALUES ($1, $2, 'auto')
       ON CONFLICT (order_id) DO UPDATE SET kcal = EXCLUDED.kcal, kcal_source = 'auto', kcal_confirmed_at = NULL, updated_at = now()
        WHERE nutrition_targets.kcal IS NULL OR (nutrition_targets.kcal_source = 'auto' AND nutrition_targets.kcal_confirmed_at IS NULL)`,
      [o.id, kcal]);
    n += r.rowCount ?? 0;
  }
  return n;
}

/** السعرات التلقائية التي تنتظر تأكيد المدربة (للوحة الإدارة) */
export async function loadPendingAuto(tx: Tx): Promise<{ order_no: string; name: string; kcal: number }[]> {
  return (await tx.query(
    `SELECT o.order_no, o.contact_name AS name, t.kcal FROM nutrition_targets t JOIN orders o ON o.id = t.order_id
      WHERE t.kcal_source = 'auto' AND t.kcal_confirmed_at IS NULL AND t.kcal IS NOT NULL
        AND o.status IN ('preparing', 'active') AND NOT o.is_demo ORDER BY o.contact_name`)).rows;
}
