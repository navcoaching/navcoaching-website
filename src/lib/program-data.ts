import type { Tx } from "@/lib/db";
import type { EditorDay, ExOption } from "@/components/admin/ProgramEditor";
import { normalizePlan, type LiftLog, type PlanWeek } from "@/lib/training";
import { computeAdherence, type Adherence, type TrainingWeek } from "@/lib/adherence";
import { addDays, reviewWeeks, riyadhDate, weekStatuses } from "@/lib/schedule";
import { DEFAULT_VOLUME_LIMIT } from "@/lib/volume";
import { loadOrderProgress } from "@/lib/order-prefetch";

/** أيام وتمارين قالب أو بلوك (للمدربة) */
export async function loadProgramDays(tx: Tx, kind: "template" | "block", ownerId: string): Promise<(EditorDay & { items: (EditorDay["items"][number] & { plan: PlanWeek[]; primary_muscle: string | null; secondary_muscles: string[] | null })[] })[]> {
  const days = kind === "template"
    ? (await tx.query(`SELECT id, day_no, title FROM template_days WHERE template_id = $1 ORDER BY day_no`, [ownerId])).rows
    : (await tx.query(`SELECT id, day_no, title FROM block_days WHERE block_id = $1 ORDER BY day_no`, [ownerId])).rows;
  const items = kind === "template"
    ? (await tx.query(
        `SELECT i.id, i.day_id, e.name, i.plan, i.note, e.primary_muscle, e.secondary_muscles FROM template_items i JOIN exercises e ON e.id = i.exercise_id
          JOIN template_days d ON d.id = i.day_id WHERE d.template_id = $1 ORDER BY i.position, i.id`, [ownerId])).rows
    : (await tx.query(
        `SELECT i.id, i.day_id, e.name, i.plan, i.note, e.primary_muscle, e.secondary_muscles, CASE WHEN i.coach_exercise_id <> i.exercise_id THEN c.name END AS coach_name,
                (SELECT count(*)::int FROM item_logs l WHERE l.block_item_id = i.id) AS logs
           FROM block_items i JOIN exercises e ON e.id = i.exercise_id JOIN exercises c ON c.id = i.coach_exercise_id
           JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1 ORDER BY i.position, i.id`, [ownerId])).rows;
  return days.map((d) => ({ ...d, items: items.filter((i) => i.day_id === d.id) }));
}

export async function loadExerciseOptions(tx: Tx): Promise<ExOption[]> {
  return (await tx.query(
    `SELECT id, name, equipment, primary_muscle, pattern, sub_pattern, anatomical_action, movement_subcategory
       FROM exercises WHERE status = 'approved' ORDER BY name`)).rows;
}

// =====================================================================
// بيانات البرنامج للعرض (المتدرب والمدربة). أسماء التمارين تأتي من app.block_exercises
// لأن المتدرب لا يقرأ جدول المكتبة مباشرة.
// =====================================================================
export type BlockRow = { id: string; order_id: string; user_id: string; name: string; start_date: string; weeks: number; instructions: string | null; steps_goal_week: number; status: string };
export type BlockExercise = { id: string; name: string; primary_muscle: string; secondary_muscles: string[]; video_url: string | null; instructions: string | null };
export type BlockItem = { id: string; day_id: string; position: number; exercise_id: string; coach_exercise_id: string; plan: PlanWeek[]; note: string | null };
export type BlockDay = { id: string; day_no: number; title: string; items: BlockItem[] };
export type ItemLog = { block_item_id: string; week_no: number; exercise_id: string; weight: number; weights: number[] | null; reps: number[]; rir: number | null; logged_at: string };
export type BlockData = {
  block: BlockRow; days: BlockDay[]; exercises: Map<string, BlockExercise>; logs: ItemLog[];
  ratings: { block_day_id: string; week_no: number; rating: number }[]; steps: { week_no: number; total: number }[];
  notes: { id: number; week_no: number | null; body: string; created_at: string }[];
};

export async function loadBlockData(tx: Tx, block: BlockRow): Promise<BlockData> {
  const days = (await tx.query(`SELECT id, day_no, title FROM block_days WHERE block_id = $1 ORDER BY day_no`, [block.id])).rows;
  const items = (await tx.query(
    `SELECT i.id, i.day_id, i.position, i.exercise_id, i.coach_exercise_id, i.plan, i.note
       FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1 ORDER BY i.position, i.id`, [block.id])).rows;
  const exercises = new Map<string, BlockExercise>(
    (await tx.query(`SELECT * FROM app.block_exercises($1)`, [block.id])).rows.map((e) => [e.id, e]));
  const logs = (await tx.query(
    `SELECT l.block_item_id, l.week_no, l.exercise_id, l.weight::float AS weight, l.weights::float[] AS weights, l.reps, l.rir::float AS rir, l.logged_at
       FROM item_logs l JOIN block_items i ON i.id = l.block_item_id JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1`, [block.id])).rows;
  const ratings = (await tx.query(
    `SELECT r.block_day_id, r.week_no, r.rating FROM day_ratings r JOIN block_days d ON d.id = r.block_day_id WHERE d.block_id = $1`, [block.id])).rows;
  const steps = (await tx.query(`SELECT week_no, total FROM step_logs WHERE block_id = $1 ORDER BY week_no`, [block.id])).rows;
  const notes = (await tx.query(`SELECT id, week_no, body, created_at FROM block_notes WHERE block_id = $1 ORDER BY created_at DESC`, [block.id])).rows;
  return {
    block, exercises, logs, ratings, steps, notes,
    days: days.map((d) => ({ ...d, items: items.filter((i) => i.day_id === d.id).map((i) => ({ ...i, plan: normalizePlan(i.plan, block.weeks) })) })),
  };
}

export type BodyData = { weights: { logged_on: string; kg: number }[]; measurements: { measured_on: string; chest: number | null; waist: number | null; hips: number | null; thigh: number | null }[] };
export async function loadBodyData(tx: Tx, userId: string): Promise<BodyData> {
  return {
    weights: (await tx.query(`SELECT logged_on::text, kg::float AS kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on`, [userId])).rows,
    measurements: (await tx.query(
      `SELECT measured_on::text, chest::float, waist::float, hips::float, thigh::float FROM body_measurements WHERE user_id = $1 ORDER BY measured_on`, [userId])).rows,
  };
}

/** كل تسجيلات المتدرب عبر كل برامجه (للأرقام القياسية) */
export async function loadAllLifts(tx: Tx, userId: string) {
  const blocks = (await tx.query(`SELECT id FROM blocks WHERE user_id = $1`, [userId])).rows.map((r) => r.id as string);
  const names = new Map<string, string>();
  for (const b of blocks) for (const e of (await tx.query(`SELECT id, name FROM app.block_exercises($1)`, [b])).rows) names.set(e.id, e.name);
  const rows = (await tx.query(
    `SELECT l.exercise_id, l.weight::float AS weight, l.weights::float[] AS weights, l.logged_at::text,
            CASE WHEN cardinality(l.reps) > 0 THEN l.reps
                 ELSE ARRAY(SELECT jsonb_array_elements_text(i.plan -> (l.week_no - 1) -> 'reps')::int) END AS reps
       FROM item_logs l
       JOIN block_items i ON i.id = l.block_item_id JOIN block_days d ON d.id = i.day_id JOIN blocks b ON b.id = d.block_id
      WHERE b.user_id = $1 AND l.weight > 0`, [userId])).rows;
  return rows.map((r) => ({ ...r, name: names.get(r.exercise_id) ?? "—" })) as LiftLog[];
}

export type AdherenceOrder = {
  id: string; months: number; sub_start_at?: string | null; sub_end_at?: string | null;
  review_weekday?: number | null; renewal_kind?: string | null;
};
/** التزام المتدرب في اشتراك واحد (تمرين + مراجعة أسبوعية). null إذا لم يبدأ الاشتراك */
export async function loadAdherence(tx: Tx, o: AdherenceOrder, reviewWindowDays: number, today = riyadhDate()): Promise<(Adherence & { rewarded: boolean }) | null> {
  if (!o.sub_start_at || !o.sub_end_at || o.months <= 0) return null;
  const d = await loadOrderProgress(tx, o.id, { training: true, reviews: o.review_weekday != null, reward: true });
  const training: TrainingWeek[] = [];
  for (const b of d.blocks) {
    const items = b.items.map((i) => ({ id: i.id, plan: normalizePlan(i.plan, b.weeks) }));
    for (let w = 1; w <= b.weeks; w++) {
      // المطلوب في الأسبوع = التمارين التي لها مجموعات فيه (وإلا كل التمارين)
      const planned = items.filter((i) => i.plan[w - 1]?.sets > 0).length || items.length;
      const logged = b.logs.find((l) => l.week_no === w)?.n ?? 0;
      training.push({ start: addDays(b.start_date, 7 * (w - 1)), logged, total: planned });
    }
  }
  let reviews: { no: number; status: "done" | "current" | "missed" | "upcoming" }[] = [];
  if (o.review_weekday != null) {
    const weeks = reviewWeeks(o.sub_start_at, o.sub_end_at, o.review_weekday, reviewWindowDays);
    reviews = weekStatuses(weeks, d.manual, d.checkins, today);
  }
  const rewarded = d.rewarded;
  return {
    ...computeAdherence({
      subStart: riyadhDate(o.sub_start_at), subEnd: riyadhDate(o.sub_end_at), months: o.months, today,
      training, reviews, isReward: o.renewal_kind === "reward",
    }),
    rewarded,
  };
}

/** حدود الجولات الأسبوعية لكل عضلة (تضعها المدربة، site_settings.volume_limits) والعضلات المتاحة في المكتبة */
export async function loadVolumeSetup(tx: Tx): Promise<{ limits: import("@/lib/volume").Limits; saved: import("@/lib/volume").Limits; muscles: string[] }> {
  const saved = (await tx.query(`SELECT value FROM site_settings WHERE key = 'volume_limits'`)).rows[0]?.value ?? {};
  const muscles = (await tx.query(
    `SELECT DISTINCT m FROM (SELECT primary_muscle m FROM exercises UNION SELECT unnest(secondary_muscles) FROM exercises) x WHERE m IS NOT NULL ORDER BY m`)).rows.map((r) => r.m as string);
  // العضلة بدون حد محفوظ تأخذ الحد الافتراضي الذي حددته المدربة (6–20)
  const limits = Object.fromEntries(muscles.map((m) => [m, saved[m] ?? DEFAULT_VOLUME_LIMIT]));
  return { limits: { ...limits, ...saved }, saved, muscles };
}
