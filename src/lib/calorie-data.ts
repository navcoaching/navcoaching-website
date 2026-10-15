import "server-only";
import { batch, litList, type Tx } from "./db";
import { currentWeight, missingFor, profileFromIntake, suggestTargets, targetKcal, type CalorieProfile, type Suggestion, type Target } from "./calorie-suggest.ts";
import { NUTRITION_SKUS } from "./intake.ts";
import { MACRO_DEFAULTS, PROTEIN_LEVELS, macrosFor, type MacroSplit, type ProteinLevel } from "./calories.ts";

export type CalorieState = {
  profile: CalorieProfile; stored: boolean; missing: string[];
  weight: { kg: number; source: "logs" | "intake" } | null;
  target: Target | null; suggestion: Suggestion | null;
  /** السعرات محسوبة تلقائياً ولم تؤكدها المدربة بعد */
  pendingAuto: boolean;
  /** الماكروز المقترحة لهدف السعرات الحالي (بروتين ودهون من الوزن، والكارب الباقي) */
  macros: Record<ProteinLevel, MacroSplit> | null;
};

const num = (v: unknown) => (v == null ? null : Number(v));

type Row = Record<string, unknown> & { order_id?: string; user_id?: string };

/** يبني حالة السعرات لطلب من الصفوف المحمّلة (نفس المنطق للطلب الواحد وللدفعة) */
function buildState(row: Row | undefined, intake: Row | undefined, logs: { logged_on: string; kg: number }[], t: Row | undefined): CalorieState {
  const { order_id: _oid, ...r } = (row ?? {}) as CalorieProfile & { order_id?: string; age: unknown; height_cm: unknown; body_fat: unknown };
  const profile: CalorieProfile = row
    ? { ...r, age: num(r.age), height_cm: num(r.height_cm), body_fat: num(r.body_fat) }
    : profileFromIntake(intake?.answers as never, intake?.health as never);
  const health = intake?.health as { weight?: unknown } | undefined;
  const weight = currentWeight(logs, num(health?.weight));
  const target: Target | null = t ? { kcal: t.kcal as number, protein: t.protein as number, carbs: t.carbs as number, fat: t.fat as number } : null;
  const pendingAuto = Boolean(t && t.kcal != null && t.kcal_source === "auto" && !t.kcal_confirmed_at);
  return {
    profile, stored: Boolean(row), missing: missingFor(profile), weight, target, pendingAuto,
    macros: target?.kcal != null && weight
      ? Object.fromEntries(PROTEIN_LEVELS.map((l) => [l.v, macrosFor(target.kcal!, weight.kg, { proteinPerKg: l.perKg, fatPerKg: MACRO_DEFAULTS.fatPerKg })])) as Record<ProteinLevel, MacroSplit>
      : null,
    // وهي بانتظار التأكيد تتحدث الحسبة نفسها تلقائياً، فلا حاجة لاقتراح منفصل
    suggestion: pendingAuto ? null : suggestTargets(profile, weight, target),
  };
}

/** حالة السعرات لعدة طلبات في رحلة واحدة (بدل أربعة استعلامات لكل طلب): مهم للوحة الإدارة والإيميل اليومي */
export async function loadCalorieStates(tx: Tx, orders: { id: string; user_id: string }[]): Promise<Map<string, CalorieState>> {
  const out = new Map<string, CalorieState>();
  if (!orders.length) return out;
  const ids = orders.map((o) => o.id), uids = [...new Set(orders.map((o) => o.user_id))];
  const by = <T extends Row>(rows: T[], key: "order_id" | "user_id") => {
    const m = new Map<string, T[]>();
    for (const r of rows) { const k = String(r[key]); (m.get(k) ?? m.set(k, []).get(k)!).push(r); }
    return m;
  };
  const [pR, iR, lR, tR] = await batch(tx, [
    `SELECT order_id, method, sex, age, height_cm::float, body_fat::float, paf::float, training_days, minutes, eb_factor::float, dismissed_kcal
       FROM calorie_profiles WHERE order_id = ANY(${litList(tx, ids, "uuid")})`,
    `SELECT order_id, answers, health FROM intakes WHERE order_id = ANY(${litList(tx, ids, "uuid")})`,
    `SELECT user_id, logged_on::text, kg::float FROM weight_logs WHERE user_id = ANY(${litList(tx, uids, "text")}) AND logged_on >= current_date - 60 ORDER BY logged_on`,
    `SELECT order_id, kcal, protein::float, carbs::float, fat::float, kcal_source, kcal_confirmed_at FROM nutrition_targets WHERE order_id = ANY(${litList(tx, ids, "uuid")})`,
  ]);
  const profiles = by(pR.rows, "order_id"), intakes = by(iR.rows, "order_id"), logs = by(lR.rows, "user_id"), targets = by(tR.rows, "order_id");
  for (const o of orders) {
    out.set(o.id, buildState(profiles.get(o.id)?.[0], intakes.get(o.id)?.[0],
      (logs.get(o.user_id) ?? []) as unknown as { logged_on: string; kg: number }[], targets.get(o.id)?.[0]));
  }
  return out;
}

/** بيانات حساب السعرات لطلب: الملف المحفوظ (أو المبدئي من الاستبيان)، الوزن الحالي، الهدف، والاقتراح */
export async function loadCalorieState(tx: Tx, orderId: string, userId: string): Promise<CalorieState> {
  return (await loadCalorieStates(tx, [{ id: orderId, user_id: userId }])).get(orderId)!;
}

/** اقتراحات السعرات المفتوحة لكل المتدربين النشطين الذين لهم أهداف (للوحة الإدارة والإيميل اليومي) */
export async function loadPendingSuggestions(tx: Tx): Promise<{ order_no: string; name: string; kcal: number; diff: number }[]> {
  const orders = (await tx.query(
    `SELECT o.id, o.order_no, o.user_id, o.contact_name FROM orders o JOIN nutrition_targets t ON t.order_id = o.id
      WHERE o.status = 'active' AND o.category = 'follow' AND NOT o.is_demo AND t.kcal IS NOT NULL ORDER BY o.contact_name`)).rows;
  const out = [];
  const states = await loadCalorieStates(tx, orders);
  for (const o of orders) {
    const s = states.get(o.id)!;
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
  const states = await loadCalorieStates(tx, rows);
  for (const o of rows) {
    const st = states.get(o.id)!;
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
