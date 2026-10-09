"use server";
// إجراءات منصة التدريب: مكتبة التمارين والقوالب والبلوك (المدربة)، والتسجيل والتبديل (المتدرب).
// كل إجراء يتحقق من الجلسة هنا، وقاعدة البيانات تتحقق مرة ثانية (RLS ودوال SECURITY DEFINER).

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser, getFreshUser } from "@/lib/session";
import { notifySafe } from "@/lib/mail";
import { notifyTrainee, RESULT_LABEL, CHANNEL_LABEL, type ChannelResult } from "@/lib/notify";
import { DEFAULT_WEEK_RIR, MAX_SETS, parseReps, parseRir, type PlanWeek } from "@/lib/training";
import { ANATOMICAL_ACTIONS, EQUIPMENT, EX_STATUS, KINDS, LEVELS, MOVEMENT_SUBCATEGORIES, MUSCLES, PATTERNS, REHAB_CATEGORIES, REHAB_LOADS, REHAB_PHASES, REHAB_REVIEW, SECONDARY_MUSCLES, SUB_PATTERNS, placeFor, type RehabReview } from "@/lib/exercises";
import type { ActionState } from "./client";
import { allow } from "@/lib/rate";
import { DEFAULT_VOLUME_LIMIT } from "@/lib/volume";
import { cleanUpload, UploadError } from "@/lib/uploads";
import { matchExercises, type DayItem, type ExtractedExercise } from "@/lib/workout-import";
import { MAX_IMAGES, readWorkoutImages, visionEnabled, VisionError } from "@/lib/workout-vision";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await getFreshUser();
  if (!u || u.role !== "coach") throw new Error("forbidden");
  return withUser(u.id, (tx) => fn(tx, u.id));
}
const fail = (err: unknown): ActionState => ({ error: dbErrorMessage(err) ?? ((err as Error).message === "forbidden" ? "لا تملكين صلاحية." : GENERIC) });

const opt = (max: number) => z.string().trim().max(max).transform((v) => v || null);
const oneOf = <T extends readonly string[]>(list: T, msg: string) =>
  z.string().refine((v) => v === "" || (list as readonly string[]).includes(v), msg).transform((v) => v || null);

const exerciseSchema = z.object({
  id: z.string().refine((v) => v === "" || UUID.test(v)),
  name: z.string().trim().min(2, "اكتبي اسم التمرين.").max(120),
  primary_muscle: z.string().refine((v) => (MUSCLES as readonly string[]).includes(v), "اختاري العضلة الأساسية."),
  secondary: z.array(z.string().refine((v) => (SECONDARY_MUSCLES as readonly string[]).includes(v))).max(6),
  pattern: oneOf(PATTERNS, "تصنيف الحركة غير صحيح."),
  kind: oneOf(KINDS, "نوع التمرين غير صحيح."),
  equipment: oneOf(EQUIPMENT, "المعدات غير صحيحة."),
  level: oneOf(LEVELS, "المستوى غير صحيح."),
  sub_pattern: oneOf(SUB_PATTERNS.map(([sp]) => sp), "النمط الفرعي غير صحيح."),
  anatomical_action: oneOf(ANATOMICAL_ACTIONS, "الحركة التشريحية غير صحيحة."),
  movement_subcategory: oneOf(MOVEMENT_SUBCATEGORIES, "التصنيف الفرعي غير صحيح."),
  status: z.enum(Object.keys(EX_STATUS) as [keyof typeof EX_STATUS]),
  video_url: opt(500).refine((v) => !v || /^https:\/\/\S+$/.test(v), "رابط الفيديو يجب أن يبدأ بـ https://"),
  instructions: opt(4000),
  notes: opt(4000),
  source: opt(120),
  source_name: opt(200),
  source_url: opt(500).refine((v) => !v || /^https?:\/\/\S+$/.test(v), "رابط المصدر غير صحيح."),
  alternatives: z.array(z.string().regex(UUID)).max(12, "الحد الأعلى 12 بديلاً."),
  rehab_categories: z.array(z.string().refine((v) => (REHAB_CATEGORIES as readonly string[]).includes(v), "التصنيف التأهيلي غير صحيح.")).max(9),
  rehab_goal: opt(300),
  rehab_phase: oneOf(REHAB_PHASES, "المرحلة غير صحيحة."),
  rehab_load: oneOf(REHAB_LOADS, "مستوى التحميل غير صحيح."),
  rehab_safety: opt(1000),
  rehab_evidence: opt(1000),
  rehab_refs: opt(2000).refine((v) => !v || v.split("|").every((u) => /^https?:\/\/\S+$/.test(u.trim())), "روابط المراجع يجب أن تبدأ بـ https:// ويُفصل بينها بـ |"),
  rehab_review: z.union([z.literal(""), z.enum(Object.keys(REHAB_REVIEW) as [RehabReview])]).transform((v) => v || null),
});

export async function saveExerciseAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const g = (k: string) => String(fd.get(k) ?? "");
  const parsed = exerciseSchema.safeParse({
    id: g("id"), name: g("name"), primary_muscle: g("primary_muscle"), secondary: fd.getAll("secondary").map(String),
    pattern: g("pattern"), kind: g("kind"), equipment: g("equipment"), level: g("level"), status: g("status"),
    sub_pattern: g("sub_pattern"), anatomical_action: g("anatomical_action"), movement_subcategory: g("movement_subcategory"),
    video_url: g("video_url"), instructions: g("instructions"), notes: g("notes"),
    source: g("source"), source_name: g("source_name"), source_url: g("source_url"),
    alternatives: [...new Set(fd.getAll("alt").map(String))],
    rehab_categories: [...new Set(fd.getAll("rehab_category").map(String))],
    rehab_goal: g("rehab_goal"), rehab_phase: g("rehab_phase"), rehab_load: g("rehab_load"), rehab_safety: g("rehab_safety"),
    rehab_evidence: g("rehab_evidence"), rehab_refs: g("rehab_refs"), rehab_review: g("rehab_review"),
  });
  if (!parsed.success) return { error: parsed.error.issues[0].message };
  const v = parsed.data;
  const parentOf = SUB_PATTERNS.find(([sp]) => sp === v.sub_pattern)?.[1];
  if (v.sub_pattern && v.pattern && parentOf !== v.pattern) return { error: "النمط الفرعي لا يتبع نمط الحركة المختار." };
  let id = v.id;
  try {
    await asCoach(async (tx, uid) => {
      const cols = [v.name, v.primary_muscle, v.secondary.filter((m) => m !== v.primary_muscle), v.pattern, v.kind, v.equipment, v.level,
        placeFor(v.equipment), v.video_url, v.instructions, v.notes, v.source, v.source_name, v.source_url, v.status,
        v.sub_pattern, v.anatomical_action, v.movement_subcategory,
        v.rehab_categories.length ? v.rehab_categories.join(" | ") : null, v.rehab_goal, v.rehab_phase, v.rehab_load, v.rehab_safety, v.rehab_evidence,
        v.rehab_refs ? v.rehab_refs.split("|").map((u) => u.trim()).filter(Boolean).join(" | ") : null, v.rehab_review];
      if (id) {
        const r = await tx.query(
          `UPDATE exercises SET name=$2, primary_muscle=$3, secondary_muscles=$4, pattern=$5, kind=$6, equipment=$7, level=$8, place=$9,
             video_url=$10, instructions=$11, notes=$12, source=$13, source_name=$14, source_url=$15, status=$16,
             sub_pattern=$17, anatomical_action=$18, movement_subcategory=$19, rehab_category=$20, rehab_goal=$21, rehab_phase=$22,
             rehab_load=$23, rehab_safety=$24, rehab_evidence=$25, rehab_refs=$26, rehab_review=$27, updated_at=now()
           WHERE id=$1`, [id, ...cols]);
        if (r.rowCount === 0) throw new Error("التمرين غير موجود.");
      } else {
        id = (await tx.query(
          `INSERT INTO exercises (name, primary_muscle, secondary_muscles, pattern, kind, equipment, level, place,
             video_url, instructions, notes, source, source_name, source_url, status, sub_pattern, anatomical_action, movement_subcategory,
             rehab_category, rehab_goal, rehab_phase, rehab_load, rehab_safety, rehab_evidence, rehab_refs, rehab_review)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26) RETURNING id`, cols)).rows[0].id;
      }
      await tx.query("DELETE FROM exercise_alternatives WHERE exercise_id = $1", [id]);
      const alts = v.alternatives.filter((a) => a !== id);
      if (alts.length) {
        await tx.query(
          `INSERT INTO exercise_alternatives (exercise_id, alt_id, position)
           SELECT $1, a, (ord - 1)::int FROM unnest($2::uuid[]) WITH ORDINALITY AS t(a, ord)
             JOIN exercises e ON e.id = t.a`, [id, alts]);
      }
      await tx.query("INSERT INTO admin_log (actor_id, action, target, details) VALUES ($1,$2,$3,$4)",
        [uid, v.id ? "exercise.update" : "exercise.create", v.name, JSON.stringify({ status: v.status })]);
    });
  } catch (err) {
    if ((err as { code?: string }).code === "23505") return { error: "يوجد تمرين بنفس الاسم في المكتبة." };
    if ((err as Error).message === "التمرين غير موجود.") return { error: "التمرين غير موجود." };
    return fail(err);
  }
  revalidatePath("/admin/exercises");
  if (!v.id) redirect(`/admin/exercises/${id}?created=1`);
  return { ok: true, message: "تم الحفظ." };
}

// =====================================================================
// القوالب وبلوك المتدرب (نفس المحرر): الأيام والتمارين وخطة الأسابيع
// =====================================================================
type Kind = "template" | "block";
const T = {
  template: { owner: "program_templates", days: "template_days", items: "template_items", fk: "template_id" },
  block: { owner: "blocks", days: "block_days", items: "block_items", fk: "block_id" },
} as const;
const kindOf = (fd: FormData): Kind | null => (fd.get("kind") === "template" ? "template" : fd.get("kind") === "block" ? "block" : null);
const idOf = (fd: FormData, k: string) => { const v = String(fd.get(k) ?? ""); return UUID.test(v) ? v : null; };

/** يحدّث صفحات المحرر والمتدرب بعد أي تعديل */
async function revalidateOwner(tx: Tx, kind: Kind, ownerId: string) {
  if (kind === "template") { revalidatePath(`/admin/templates/${ownerId}`); return; }
  const { rows: [o] } = await tx.query("SELECT o.order_no FROM blocks b JOIN orders o ON o.id = b.order_id WHERE b.id = $1", [ownerId]);
  if (o) { revalidatePath(`/admin/orders/${o.order_no}/program`); revalidatePath(`/account/orders/${o.order_no}/training`); }
}
async function ownerOfDay(tx: Tx, kind: Kind, dayId: string) {
  const t = T[kind];
  const { rows: [r] } = await tx.query(`SELECT d.${t.fk} AS owner, o.weeks FROM ${t.days} d JOIN ${t.owner} o ON o.id = d.${t.fk} WHERE d.id = $1`, [dayId]);
  if (!r) throw new Error("gone");
  return r as { owner: string; weeks: number };
}
async function ownerOfItem(tx: Tx, kind: Kind, itemId: string) {
  const t = T[kind];
  const { rows: [r] } = await tx.query(
    `SELECT i.day_id, d.${t.fk} AS owner, o.weeks FROM ${t.items} i JOIN ${t.days} d ON d.id = i.day_id JOIN ${t.owner} o ON o.id = d.${t.fk} WHERE i.id = $1`, [itemId]);
  if (!r) throw new Error("gone");
  return r as { day_id: string; owner: string; weeks: number };
}
async function exerciseByName(tx: Tx, name: string, allowId?: string | null) {
  const { rows: [e] } = await tx.query(
    `SELECT id FROM exercises WHERE lower(trim(name)) = lower(trim($1)) AND (status = 'approved' OR id::text = $2)`, [name, allowId ?? ""]);
  return (e?.id as string | undefined) ?? null;
}
/** يضع التمرين في الترتيب المطلوب داخل يومه (1 = الأول) ويعيد ترقيم الباقي */
async function placeAt(tx: Tx, table: string, dayId: string, itemId: string, pos: number | null) {
  if (pos == null) return;
  const ids = (await tx.query(`SELECT id FROM ${table} WHERE day_id = $1 AND id <> $2 ORDER BY position, id`, [dayId, itemId])).rows.map((r) => r.id as string);
  ids.splice(Math.min(Math.max(pos - 1, 0), ids.length), 0, itemId);
  await tx.query(`UPDATE ${table} SET position = x.ord - 1 FROM unnest($1::uuid[]) WITH ORDINALITY AS x(id, ord) WHERE ${table}.id = x.id`, [ids]);
}
/** رقم الترتيب من النموذج (فارغ = بدون تغيير) */
const positionOf = (fd: FormData) => { const n = Number(String(fd.get("position") ?? "").trim()); return Number.isInteger(n) && n >= 1 && n <= 60 ? n : null; };
const trainingFail = (err: unknown): ActionState =>
  (err as Error).message === "gone" ? { error: "العنصر غير موجود، حدّثي الصفحة." } : fail(err);

const templateSchema = z.object({
  id: z.string().refine((v) => v === "" || UUID.test(v)),
  name: z.string().trim().min(2, "اكتبي اسم القالب.").max(120),
  weeks: z.coerce.number().int().min(1).max(12, "عدد الأسابيع من 1 إلى 12."),
  instructions: opt(4000),
  archived: z.boolean(),
  public: z.boolean(),
  public_summary: opt(300),
});

export async function saveTemplateAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const g = (k: string) => String(fd.get(k) ?? "");
  const p = templateSchema.safeParse({ id: g("id"), name: g("name"), weeks: g("weeks") || "5", instructions: g("instructions"), archived: fd.get("archived") === "on",
    public: fd.get("public") === "on", public_summary: g("public_summary") });
  if (!p.success) return { error: p.error.issues[0].message };
  const v = p.data;
  let id = v.id;
  try {
    await asCoach(async (tx) => {
      if (id) {
        const r = await tx.query(`UPDATE program_templates SET name=$2, weeks=$3, instructions=$4, archived=$5, public=$6, public_summary=$7, updated_at=now() WHERE id=$1`,
          [id, v.name, v.weeks, v.instructions, v.archived, v.public, v.public_summary]);
        if (!r.rowCount) throw new Error("gone");
      } else {
        id = (await tx.query(`INSERT INTO program_templates (name, weeks, instructions) VALUES ($1,$2,$3) RETURNING id`, [v.name, v.weeks, v.instructions])).rows[0].id;
        await tx.query(`INSERT INTO template_days (template_id, day_no, title) VALUES ($1, 1, 'DAY 1')`, [id]);
      }
    });
  } catch (err) { return trainingFail(err); }
  revalidatePath("/admin/templates");
  revalidatePath(`/admin/templates/${id}`);
  if (!v.id) redirect(`/admin/templates/${id}?created=1`);
  return { ok: true, message: "تم الحفظ." };
}

/** نسخ قالب كامل (للبدء من قالب قريب) */
export async function duplicateTemplateAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const src = idOf(fd, "id");
  if (!src) return { error: "القالب غير موجود." };
  let id = "";
  try {
    id = await asCoach(async (tx) => {
      const { rows: [n] } = await tx.query(
        `INSERT INTO program_templates (name, weeks, instructions) SELECT left(name || ' (نسخة)', 120), weeks, instructions FROM program_templates WHERE id = $1 RETURNING id`, [src]);
      if (!n) throw new Error("gone");
      const days = (await tx.query(`SELECT id, day_no, title FROM template_days WHERE template_id = $1`, [src])).rows;
      for (const d of days) {
        const { rows: [nd] } = await tx.query(`INSERT INTO template_days (template_id, day_no, title) VALUES ($1,$2,$3) RETURNING id`, [n.id, d.day_no, d.title]);
        await tx.query(`INSERT INTO template_items (day_id, position, exercise_id, plan, note) SELECT $1, position, exercise_id, plan, note FROM template_items WHERE day_id = $2`, [nd.id, d.id]);
      }
      return n.id as string;
    });
  } catch (err) { return trainingFail(err); }
  revalidatePath("/admin/templates");
  redirect(`/admin/templates/${id}?created=1`);
}

export async function addDayAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), owner = idOf(fd, "owner");
  const title = String(fd.get("title") ?? "").trim();
  if (!kind || !owner) return { error: GENERIC };
  if (!title || title.length > 80) return { error: "اكتبي عنوان اليوم (حتى 80 حرفاً)." };
  const t = T[kind];
  try {
    await asCoach(async (tx) => {
      const { rows: [{ n }] } = await tx.query(`SELECT coalesce(max(day_no), 0) + 1 AS n FROM ${t.days} WHERE ${t.fk} = $1`, [owner]);
      if (n > 14) throw Object.assign(new Error("limit"), {});
      await tx.query(`INSERT INTO ${t.days} (${t.fk}, day_no, title) VALUES ($1,$2,$3)`, [owner, n, title]);
      await revalidateOwner(tx, kind, owner);
    });
  } catch (err) {
    if ((err as Error).message === "limit") return { error: "الحد الأعلى 14 يوماً." };
    return trainingFail(err);
  }
  return { ok: true, message: "تمت إضافة اليوم." };
}

export async function saveDayAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), day = idOf(fd, "day");
  const title = String(fd.get("title") ?? "").trim();
  if (!kind || !day) return { error: GENERIC };
  if (!title || title.length > 80) return { error: "اكتبي عنوان اليوم (حتى 80 حرفاً)." };
  try {
    await asCoach(async (tx) => {
      const o = await ownerOfDay(tx, kind, day);
      await tx.query(`UPDATE ${T[kind].days} SET title = $2 WHERE id = $1`, [day, title]);
      await revalidateOwner(tx, kind, o.owner);
    });
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deleteDayAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), day = idOf(fd, "day");
  if (!kind || !day) return { error: GENERIC };
  const t = T[kind];
  try {
    await asCoach(async (tx) => {
      const o = await ownerOfDay(tx, kind, day);
      const { rows: [gone] } = await tx.query(`DELETE FROM ${t.days} WHERE id = $1 RETURNING day_no`, [day]);
      // إعادة ترقيم الأيام التالية (واحداً واحداً تصاعدياً حتى لا يتعارض الترقيم)
      const after = (await tx.query(`SELECT id FROM ${t.days} WHERE ${t.fk} = $1 AND day_no > $2 ORDER BY day_no`, [o.owner, gone.day_no])).rows;
      for (const d of after) await tx.query(`UPDATE ${t.days} SET day_no = day_no - 1 WHERE id = $1`, [d.id]);
      await revalidateOwner(tx, kind, o.owner);
    });
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تم حذف اليوم." };
}

/** إضافة تمرين ليوم: «3x10» و RIR تُطبّق على كل الأسابيع، وتُعدَّل بعدها لكل أسبوع */
export async function addItemAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), day = idOf(fd, "day");
  if (!kind || !day) return { error: GENERIC };
  const name = String(fd.get("exercise") ?? "").trim();
  const pickedId = idOf(fd, "exercise_id");
  const reps = parseReps(String(fd.get("reps") ?? ""));
  const rir = parseRir(String(fd.get("rir") ?? ""));
  if (!name && !pickedId) return { error: "اختاري التمرين من القائمة." };
  if (reps === null) return { error: "اكتبي المجموعات والتكرارات مثل 3x12 أو 12-10-8." };
  if (rir === undefined) return { error: "RIR رقم من 0 إلى 10." };
  const t = T[kind];
  try {
    const res = await asCoach(async (tx) => {
      const o = await ownerOfDay(tx, kind, day);
      const ex = pickedId
        ? ((await tx.query(`SELECT id FROM exercises WHERE id = $1 AND status = 'approved'`, [pickedId])).rows[0]?.id as string | undefined) ?? null
        : await exerciseByName(tx, name);
      if (!ex) return { error: "التمرين غير موجود في المكتبة أو غير معتمد. اختاريه من القائمة." };
      const plan: PlanWeek[] = Array.from({ length: o.weeks }, (_, w) => ({ sets: reps.length, reps, rir: rir ?? DEFAULT_WEEK_RIR[Math.min(w, DEFAULT_WEEK_RIR.length - 1)] }));
      const { rows: [{ pos }] } = await tx.query(`SELECT coalesce(max(position), -1) + 1 AS pos FROM ${t.items} WHERE day_id = $1`, [day]);
      const { rows: [ins] } = kind === "block"
        ? await tx.query(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) VALUES ($1,$2,$3,$3,$4) RETURNING id`, [day, pos, ex, JSON.stringify(plan)])
        : await tx.query(`INSERT INTO template_items (day_id, position, exercise_id, plan) VALUES ($1,$2,$3,$4) RETURNING id`, [day, pos, ex, JSON.stringify(plan)]);
      await placeAt(tx, t.items, day, ins.id, positionOf(fd));
      await revalidateOwner(tx, kind, o.owner);
      return null;
    });
    if (res) return res;
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تمت إضافة التمرين." };
}

/** حفظ تمرين: التمرين نفسه وخطة كل أسبوع (w1_reps, w1_rir, ...) والملاحظة */
export async function saveItemAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), item = idOf(fd, "item");
  if (!kind || !item) return { error: GENERIC };
  const name = String(fd.get("exercise") ?? "").trim();
  const pickedId = idOf(fd, "exercise_id");
  const note = String(fd.get("note") ?? "").trim();
  if (!name && !pickedId) return { error: "اختاري التمرين من القائمة." };
  if (note.length > 500) return { error: "الملاحظة حتى 500 حرف." };
  const copyFirst = fd.get("copy_first") === "on";
  const t = T[kind];
  try {
    const res = await asCoach(async (tx) => {
      const o = await ownerOfItem(tx, kind, item);
      const { rows: [cur] } = await tx.query(`SELECT exercise_id, day_id FROM ${t.items} WHERE id = $1`, [item]);
      const ex = pickedId
        ? ((await tx.query(`SELECT id FROM exercises WHERE id = $1 AND (status = 'approved' OR id = $2)`, [pickedId, cur.exercise_id])).rows[0]?.id as string | undefined) ?? null
        : await exerciseByName(tx, name, cur.exercise_id);
      if (!ex) return { error: "التمرين غير موجود في المكتبة أو غير معتمد. اختاريه من القائمة." };
      const plan: PlanWeek[] = [];
      for (let w = 1; w <= o.weeks; w++) {
        const src = copyFirst ? 1 : w;
        const reps = parseReps(String(fd.get(`w${src}_reps`) ?? ""));
        const rir = parseRir(String(fd.get(`w${src}_rir`) ?? ""));
        if (reps === null) return { error: `الأسبوع ${src}: اكتبي التكرارات مثل 3x12 أو 12-10-8.` };
        if (rir === undefined) return { error: `الأسبوع ${src}: RIR رقم من 0 إلى 10.` };
        plan.push({ sets: reps.length, reps, rir });
      }
      if (kind === "block") {
        // تغيير المدربة للتمرين يصبح هو اختيارها الأصلي (أساس بدائل المتدرب)
        await tx.query(
          `UPDATE block_items SET exercise_id = $2, coach_exercise_id = CASE WHEN $2 = exercise_id THEN coach_exercise_id ELSE $2 END, plan = $3, note = $4 WHERE id = $1`,
          [item, ex, JSON.stringify(plan), note || null]);
      } else {
        await tx.query(`UPDATE template_items SET exercise_id = $2, plan = $3, note = $4 WHERE id = $1`, [item, ex, JSON.stringify(plan), note || null]);
      }
      await placeAt(tx, t.items, cur.day_id, item, positionOf(fd));
      await revalidateOwner(tx, kind, o.owner);
      return null;
    });
    if (res) return res;
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: copyFirst ? "تم الحفظ ونسخ الأسبوع 1 لكل الأسابيع." : "تم الحفظ." };
}

export async function deleteItemAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), item = idOf(fd, "item");
  if (!kind || !item) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const o = await ownerOfItem(tx, kind, item);
      await tx.query(`DELETE FROM ${T[kind].items} WHERE id = $1`, [item]);
      await revalidateOwner(tx, kind, o.owner);
    });
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تم الحذف." };
}

export async function moveItemAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const kind = kindOf(fd), item = idOf(fd, "item");
  const dir = fd.get("dir") === "up" ? -1 : 1;
  if (!kind || !item) return { error: GENERIC };
  const t = T[kind];
  try {
    await asCoach(async (tx) => {
      const o = await ownerOfItem(tx, kind, item);
      const ids = (await tx.query(`SELECT id FROM ${t.items} WHERE day_id = $1 ORDER BY position, id`, [o.day_id])).rows.map((r) => r.id as string);
      const i = ids.indexOf(item), j = i + dir;
      if (j < 0 || j >= ids.length) return;
      [ids[i], ids[j]] = [ids[j], ids[i]];
      await tx.query(`UPDATE ${t.items} SET position = x.ord - 1 FROM unnest($1::uuid[]) WITH ORDINALITY AS x(id, ord) WHERE ${t.items}.id = x.id`, [ids]);
      await revalidateOwner(tx, kind, o.owner);
    });
  } catch (err) { return trainingFail(err); }
  return { ok: true };
}

// ---------- بلوك المتدرب (من صفحة الطلب) ----------
const summarize = (r: ChannelResult[]) =>
  r.length ? " الإشعار: " + r.map((x) => `${CHANNEL_LABEL[x.channel]} — ${RESULT_LABEL[x.status]}${x.detail ? ` (${x.detail})` : ""}`).join("، ") : "";

async function notifyProgram(tx: Tx, orderNo: string, text: string) {
  const { rows: [o] } = await tx.query(`SELECT id, user_id FROM orders WHERE order_no = $1`, [orderNo]);
  if (!o) return [];
  return notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, { kind: "program", subject: "تحديث على برنامج التمرين", text });
}
const ORDER_NO = /^[A-Z]{2,5}-\d{6}-[A-Z0-9]{3,8}$/;

export async function assignTemplateAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const tpl = idOf(fd, "template");
  const start = String(fd.get("start_date") ?? "");
  const name = String(fd.get("name") ?? "").trim().slice(0, 120);
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  if (!tpl) return { error: "اختاري القالب." };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) return { error: "اختاري تاريخ البداية." };
  let results: ChannelResult[] = [];
  try {
    results = await asCoach(async (tx) => {
      await tx.query("SELECT app.coach_assign_template($1,$2,$3,$4)", [orderNo, tpl, start, name || null]);
      return fd.get("notify") === "on" ? notifyProgram(tx, orderNo, "جهّزت لك المدربة برنامج التمرين. تقدر تشوفه وتسجّل تمارينك من حسابك في الموقع.") : [];
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/program`);
  revalidatePath(`/admin/orders/${orderNo}`);
  revalidatePath(`/account/orders/${orderNo}/training`);
  // الصفحة تتحول من نموذج الإسناد إلى البرنامج، فنعرض النتيجة بعد التحويل
  const n = results.map((r) => `${r.channel}:${r.status}`).join(",");
  redirect(`/admin/orders/${orderNo}/program?assigned=1${n ? `&n=${encodeURIComponent(n)}` : ""}`);
}

const blockSchema = z.object({
  id: z.string().regex(UUID),
  name: z.string().trim().min(1, "اكتبي اسم البرنامج.").max(120),
  start_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "اختاري تاريخ البداية."),
  weeks: z.coerce.number().int().min(1).max(12, "عدد الأسابيع من 1 إلى 12."),
  steps_goal_week: z.coerce.number().int().min(0).max(300000, "هدف الخطوات غير منطقي."),
  instructions: opt(4000),
});

export async function saveBlockAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const g = (k: string) => String(fd.get(k) ?? "");
  const p = blockSchema.safeParse({ id: g("id"), name: g("name"), start_date: g("start_date"), weeks: g("weeks"), steps_goal_week: g("steps_goal_day") ? String(Math.round(Number(g("steps_goal_day")) * 7)) : g("steps_goal_week") || "0", instructions: g("instructions") });
  if (!p.success) return { error: p.error.issues[0].message };
  const v = p.data;
  try {
    const res = await asCoach(async (tx) => {
      const { rows: [{ maxw }] } = await tx.query(
        `SELECT greatest(coalesce((SELECT max(l.week_no) FROM item_logs l JOIN block_items i ON i.id = l.block_item_id JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1), 0),
                         coalesce((SELECT max(week_no) FROM step_logs WHERE block_id = $1), 0)) AS maxw`, [v.id]);
      if (v.weeks < maxw) return { error: `المتدرب سجّل حتى الأسبوع ${maxw}، فلا يمكن تقليل الأسابيع لأقل من ذلك.` };
      const r = await tx.query(`UPDATE blocks SET name=$2, start_date=$3, weeks=$4, steps_goal_week=$5, instructions=$6, updated_at=now() WHERE id=$1`,
        [v.id, v.name, v.start_date, v.weeks, v.steps_goal_week, v.instructions]);
      if (!r.rowCount) throw new Error("gone");
      await revalidateOwner(tx, "block", v.id);
      return null;
    });
    if (res) return res;
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تم الحفظ." };
}

export async function archiveBlockAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = idOf(fd, "id");
  if (!id) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const r = await tx.query(`UPDATE blocks SET status = 'archived', updated_at = now() WHERE id = $1 AND status = 'active'`, [id]);
      if (!r.rowCount) throw new Error("gone");
      await revalidateOwner(tx, "block", id);
    });
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تم إنهاء البرنامج. يبقى ظاهراً للمتدرب للقراءة فقط." };
}

/** حذف برنامج أُضيف بالخطأ (فقط إذا ما سجّل المتدرب عليه شيئاً، والقاعدة تتحقق) */
export async function deleteBlockAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = idOf(fd, "id");
  if (!id) return { error: GENERIC };
  let orderNo = "";
  try {
    orderNo = await asCoach(async (tx) => (await tx.query("SELECT app.coach_delete_block($1) AS no", [id])).rows[0].no as string);
  } catch (err) { return trainingFail(err); }
  revalidatePath(`/admin/orders/${orderNo}/program`);
  revalidatePath(`/admin/orders/${orderNo}`);
  revalidatePath(`/account/orders/${orderNo}/training`);
  redirect(`/admin/orders/${orderNo}/program?deleted=1`);
}

export async function notifyProgramAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  let results: ChannelResult[] = [];
  try {
    results = await asCoach((tx) => notifyProgram(tx, orderNo, "حدّثت المدربة برنامج التمرين الخاص بك. افتح حسابك في الموقع لتشوف التعديلات."));
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم." + summarize(results) };
}

export async function addBlockNoteAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const block = idOf(fd, "block");
  const body = String(fd.get("body") ?? "").trim();
  const wk = String(fd.get("week_no") ?? "");
  const week = wk ? Number(wk) : null;
  if (!block) return { error: GENERIC };
  if (!body) return { error: "اكتبي الملاحظة أولاً." };
  if (body.length > 3000) return { error: "الملاحظة أطول من 3000 حرف." };
  if (week != null && !(Number.isInteger(week) && week >= 1 && week <= 12)) return { error: "رقم الأسبوع غير صحيح." };
  try {
    await asCoach(async (tx, uid) => {
      await tx.query(`INSERT INTO block_notes (block_id, week_no, body, created_by) VALUES ($1,$2,$3,$4)`, [block, week, body, uid]);
      await revalidateOwner(tx, "block", block);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تمت إضافة الملاحظة، وتظهر للمتدرب في صفحة برنامجه." };
}

export async function deleteBlockNoteAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = Number(fd.get("id"));
  if (!Number.isSafeInteger(id)) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const { rows: [n] } = await tx.query(`DELETE FROM block_notes WHERE id = $1 RETURNING block_id`, [id]);
      if (!n) throw new Error("gone");
      await revalidateOwner(tx, "block", n.block_id);
    });
  } catch (err) { return trainingFail(err); }
  return { ok: true, message: "تم الحذف." };
}

export async function markSwapsSeenAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = String(fd.get("user_id") ?? "");
  if (!user || user.length > 100) return { error: GENERIC };
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_mark_swaps_seen($1)", [user]));
  } catch (err) { return fail(err); }
  revalidatePath("/admin/members");
  revalidatePath("/admin");
  const back = String(fd.get("back") ?? "");
  if (/^\/admin\/orders\/[A-Z0-9-]+\/program$/.test(back)) revalidatePath(back);
  return { ok: true, message: "تم." };
}

// =====================================================================
// المتدرب: التسجيل والتبديل والتقدم (الكتابة عبر دوال قاعدة البيانات فقط)
// =====================================================================
const T_GENERIC = "تعذّر الحفظ. حاول مرة أخرى.";
async function asTrainee<T>(fn: (tx: Tx, user: { id: string; name: string }) => Promise<T>): Promise<T> {
  const u = await getCurrentUser();
  if (!u) throw new Error("login");
  return withUser(u.id, (tx) => fn(tx, u));
}
const tFail = (err: unknown): ActionState =>
  ({ error: (err as Error).message === "login" ? "سجّل الدخول أولاً." : dbErrorMessage(err) ?? T_GENERIC });
const orderPath = (fd: FormData) => {
  const no = String(fd.get("order_no") ?? "");
  return ORDER_NO.test(no) ? `/account/orders/${no}/training` : null;
};
/** الوزن والقياسات والخطوات تظهر في صفحة التقدم */
const progressPath = (fd: FormData) => {
  const no = String(fd.get("order_no") ?? "");
  return ORDER_NO.test(no) ? `/account/orders/${no}/progress` : null;
};
const toNum = (v: FormDataEntryValue | null) => {
  const s = String(v ?? "").trim().replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(",", ".");
  return s === "" ? null : Number(s);
};

const NEED_REPS = "اكتب تكرارات الجولة الأولى.";
/**
 * تسجيل تمرين بوزن لكل جولة. الجولة الفارغة الوزن تأخذ وزن اللي قبلها،
 * والفارغة التكرارات تأخذ المستهدف لتلك الجولة. الجولات الزائدة الفارغة تُتجاهل.
 */
export async function logItemAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const item = idOf(fd, "item");
  const week = Number(fd.get("week"));
  const clear = fd.get("clear") === "1";
  if (!item || !Number.isInteger(week)) return { error: T_GENERIC };
  const rawW = fd.getAll("set_weight").map((v) => toNum(v));
  const rawR = fd.getAll("reps").map((v) => toNum(v));
  const rir = toNum(fd.get("rir"));
  if (!clear) {
    if (rawW[0] == null) return { error: "اكتب وزن الجولة الأولى بالكيلو (0 لتمارين وزن الجسم)." };
    if ([...rawW, ...rawR].some((v) => v != null && !Number.isFinite(v))) return { error: "الأوزان والتكرارات أرقام." };
    if (rawW.some((w) => w != null && (w < 0 || w > 1000))) return { error: "الوزن بين 0 و 1000 كغ." };
    if (rawR.some((r) => r != null && (!Number.isInteger(r) || r < 0 || r > 200))) return { error: "التكرارات أرقام صحيحة." };
    if (rir != null && (!Number.isFinite(rir) || rir < 0 || rir > 10)) return { error: "RIR رقم من 0 إلى 10." };
  }
  try {
    await asTrainee(async (tx) => {
      if (clear) return tx.query("SELECT app.log_item_sets($1,$2,NULL,NULL,NULL)", [item, week]);
      const { rows: [it] } = await tx.query("SELECT plan FROM block_items WHERE id = $1", [item]);
      const target: number[] = Array.isArray(it?.plan?.[week - 1]?.reps) ? it.plan[week - 1].reps.map(Number) : [];
      const weights: number[] = [], reps: number[] = [];
      let last = rawW[0]!;
      for (let i = 0; i < Math.min(MAX_SETS, Math.max(rawW.length, rawR.length)); i++) {
        const r = rawR[i] ?? target[i];
        if (r == null) continue; // جولة زائدة بدون تكرارات ولا مستهدف
        if (rawW[i] != null) last = rawW[i]!;
        weights.push(last); reps.push(r);
      }
      if (!weights.length) throw new Error(NEED_REPS);
      return tx.query("SELECT app.log_item_sets($1,$2,$3,$4,$5)", [item, week, weights, reps, rir]);
    });
  } catch (err) {
    if ((err as Error).message === NEED_REPS) return { error: NEED_REPS };
    return tFail(err);
  }
  const p = orderPath(fd); if (p) revalidatePath(p);
  return { ok: true, message: clear ? "تم حذف التسجيل." : "تم الحفظ ✅" };
}

export async function rateDayAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const day = idOf(fd, "day");
  const week = Number(fd.get("week")), rating = Number(fd.get("rating"));
  if (!day || !Number.isInteger(week)) return { error: T_GENERIC };
  if (!(rating >= 1 && rating <= 5)) return { error: "اختر تقييماً من 1 إلى 5." };
  try {
    await asTrainee((tx) => tx.query("SELECT app.rate_day($1,$2,$3)", [day, week, rating]));
  } catch (err) { return tFail(err); }
  const p = orderPath(fd); if (p) revalidatePath(p);
  return { ok: true, message: "شكراً، تم حفظ تقييم اليوم." };
}

/** تبديل تمرين ببديله من القائمة + إشعار المدربة (داخل لوحة الإدارة، وبالبريد إن كان مفعّلاً) */
export async function swapExerciseAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const item = idOf(fd, "item"), ex = idOf(fd, "exercise");
  const no = String(fd.get("order_no") ?? "");
  if (!item || !ex || !ORDER_NO.test(no)) return { error: "اختر التمرين البديل من القائمة." };
  let r: { changed: boolean; from?: string; to?: string };
  let who = "";
  try {
    r = await asTrainee(async (tx, u) => {
      who = u.name;
      return (await tx.query("SELECT app.swap_exercise($1,$2) AS r", [item, ex])).rows[0].r;
    });
  } catch (err) { return tFail(err); }
  if (r.changed) {
    const site = process.env.NEXT_PUBLIC_SITE_URL ?? "";
    await notifySafe(process.env.COACH_NOTIFY_EMAIL, `تبديل تمرين — ${who}`,
      `${who} بدّل تمريناً في برنامجه:\n${r.from} ← ${r.to}\n\nالتفاصيل:\n${site}/admin/orders/${no}/program\n\nNav Coaching`);
    revalidatePath(`/account/orders/${no}/training`);
    revalidatePath("/admin/members");
  }
  return { ok: true, message: r.changed ? `تم التبديل إلى ${r.to}. وصل إشعار للمدربة.` : "هذا هو التمرين الحالي." };
}

export async function logStepsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const block = idOf(fd, "block");
  const week = Number(fd.get("week"));
  const total = toNum(fd.get("total"));
  if (!block || !Number.isInteger(week)) return { error: T_GENERIC };
  if (total != null && (!Number.isInteger(total) || total < 0 || total > 500000)) return { error: "اكتب مجموع خطوات الأسبوع رقماً صحيحاً." };
  try {
    await asTrainee((tx) => tx.query("SELECT app.log_steps($1,$2,$3)", [block, week, total]));
  } catch (err) { return tFail(err); }
  const p = orderPath(fd); if (p) revalidatePath(p);
  const pp = progressPath(fd); if (pp) revalidatePath(pp);
  return { ok: true, message: total == null ? "تم الحذف." : "تم حفظ الخطوات." };
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;
export async function logWeightAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const date = String(fd.get("date") ?? "");
  const kg = toNum(fd.get("kg"));
  if (!DATE.test(date)) return { error: "اختر التاريخ." };
  if (kg != null && (!Number.isFinite(kg) || kg < 25 || kg > 350)) return { error: "اكتب الوزن بالكيلو (مثل 72.4)." };
  try {
    await asTrainee((tx) => tx.query("SELECT app.log_weight($1,$2)", [date, kg]));
  } catch (err) { return tFail(err); }
  const p = orderPath(fd); if (p) revalidatePath(p);
  const pp = progressPath(fd); if (pp) revalidatePath(pp);
  return { ok: true, message: kg == null ? "تم حذف الوزن لهذا اليوم." : "تم حفظ الوزن." };
}

export async function logMeasurementsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const date = String(fd.get("date") ?? "");
  const vals = ["chest", "waist", "hips", "thigh"].map((k) => toNum(fd.get(k)));
  if (!DATE.test(date)) return { error: "اختر التاريخ." };
  if (vals.some((v) => v != null && !Number.isFinite(v))) return { error: "القياسات أرقام بالسنتيمتر." };
  if (vals.every((v) => v == null)) return { error: "اكتب قياساً واحداً على الأقل." };
  try {
    await asTrainee((tx) => tx.query("SELECT app.log_measurements($1,$2,$3,$4,$5)", [date, ...vals]));
  } catch (err) { return tFail(err); }
  const p = orderPath(fd); if (p) revalidatePath(p);
  const pp = progressPath(fd); if (pp) revalidatePath(pp);
  return { ok: true, message: "تم حفظ القياسات." };
}

// ---------- تعبئة التسجيل من صورة تطبيق خارجي (Strong وغيره) ----------
export type ImportPreview = ActionState & {
  rows?: { external: string; key: string; itemId: string | null; how: string | null; weights: number[]; reps: number[]; rir: number | null }[];
  items?: { id: string; name: string }[];
};

/** يقرأ الصورة ويطابق التمارين ويرجع معاينة للمراجعة. لا يحفظ شيئاً ولا يخزّن الصورة. */
export async function readWorkoutImageAction(_: ImportPreview, fd: FormData): Promise<ImportPreview> {
  const u = await getCurrentUser();
  if (!u) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  const day = idOf(fd, "day");
  if (!ORDER_NO.test(orderNo) || !day) return { error: T_GENERIC };
  if (!visionEnabled()) return { error: "قراءة الصور غير مفعّلة حالياً." };
  if (!(await allow(`vision:u:${u.id}`, 10, 3600))) return { error: "وصلت الحد (10 صور في الساعة). حاول لاحقاً أو سجّل يدوياً." };
  // سقف يومي للموقع كله (خدمة مدفوعة لكل صورة): يمنع أي ارتفاع مفاجئ في التكلفة حتى من حسابات كثيرة
  if (!(await allow("vision:site:day", Number(process.env.VISION_DAILY_CAP ?? 150), 86400))) return { error: "قراءة الصور متوقفة مؤقتاً لليوم. سجّل يدوياً، وترجع الخدمة بكرة." };

  const ctx = await withUser(u.id, async (tx) => {
    const { rows: [b] } = await tx.query(
      `SELECT b.id FROM block_days d JOIN blocks b ON b.id = d.block_id JOIN orders o ON o.id = b.order_id
        WHERE d.id = $1 AND o.order_no = $2 AND b.user_id = $3 AND b.status = 'active'`, [day, orderNo, u.id]);
    if (!b) return null;
    const items = (await tx.query(
      `SELECT i.id, i.exercise_id, e.name FROM block_items i JOIN app.block_exercises($2) e ON e.id = i.exercise_id
        WHERE i.day_id = $1 ORDER BY i.position, i.id`, [day, b.id])).rows as DayItem[];
    const aliases = new Map<string, string>((await tx.query(
      `SELECT external_name, exercise_id FROM exercise_aliases WHERE user_id = $1`, [u.id])).rows.map((r) => [r.external_name, r.exercise_id]));
    return { items, aliases };
  });
  if (!ctx) return { error: "البرنامج غير موجود أو منتهي." };

  let extracted: ExtractedExercise[];
  try {
    const files = fd.getAll("image").filter((f): f is File => f instanceof File && f.size > 0);
    if (!files.length) throw new UploadError("اختر صورة.");
    if (files.length > MAX_IMAGES) throw new UploadError(`حتى ${MAX_IMAGES} صور في المرة.`);
    const imgs = [];
    for (const f of files) imgs.push(await cleanUpload(f, "image"));
    extracted = await readWorkoutImages(imgs.map((i) => ({ data: i.data, mime: i.mime })));
  } catch (err) {
    if (err instanceof UploadError || err instanceof VisionError) return { error: err.message };
    console.error("[vision] action", (err as Error).name, (err as Error).message);
    return { error: `تعذّرت قراءة الصورة الآن. سجّل يدوياً أو حاول لاحقاً. (رمز: V-A-${(err as Error).name || "ERR"})` };
  }
  const rows = matchExercises(extracted, ctx.items, ctx.aliases).map((r) => ({
    external: r.external, key: r.key, itemId: r.itemId, how: r.how,
    weights: r.log?.weights ?? [], reps: r.log?.reps ?? [], rir: r.log?.rir ?? null,
  }));
  return { ok: true, rows, items: ctx.items.map((i) => ({ id: i.id, name: i.name })) };
}

/** يحفظ ما راجعه المتدرب: تسجيل كل تمرين بوزن لكل جولة (app.log_item_sets) وربط الأسماء الجديدة للمرات الجاية */
export async function saveImportedLogsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const week = Number(fd.get("week"));
  const count = Math.min(30, Number(fd.get("count")) || 0);
  if (!Number.isInteger(week) || week < 1) return { error: T_GENERIC };
  const entries: { item: string; weights: number[]; reps: number[]; rir: number | null; key: string; how: string }[] = [];
  for (let k = 0; k < count; k++) {
    const item = String(fd.get(`item_${k}`) ?? "");
    if (!item) continue; // «تجاهل»
    if (!UUID.test(item)) return { error: T_GENERIC };
    const reps = String(fd.get(`reps_${k}`) ?? "").split(/[^0-9٠-٩]+/).filter(Boolean).map((v) => toNum(v)!);
    if (!reps.length || reps.length > 10 || reps.some((r) => !Number.isInteger(r) || r < 0 || r > 200)) return { error: `التكرارات للتمرين ${k + 1} أرقام مفصولة بفواصل.` };
    // الأوزان لكل جولة؛ وزن واحد = لكل الجولات، والناقص يأخذ آخر وزن
    const ws = String(fd.get(`weights_${k}`) ?? "").split(/[\s,،;]+/).filter(Boolean).map((v) => toNum(v.replace("٫", ".")));
    if (!ws.length || ws.length > reps.length || ws.some((w) => w == null || !Number.isFinite(w) || w < 0 || w > 1000)) return { error: `اكتب الوزن بالكيلو لكل جولة في التمرين ${k + 1} مفصولة بفواصل.` };
    const weights = reps.map((_, i) => (ws[i] ?? ws[ws.length - 1]) as number);
    const rir = toNum(fd.get(`rir_${k}`));
    if (rir != null && (!Number.isFinite(rir) || rir < 0 || rir > 10)) return { error: "RIR رقم من 0 إلى 10." };
    if (entries.some((e) => e.item === item)) return { error: "ربطت تمرينين من الصورة بنفس تمرين البرنامج. اختر «تجاهل» لأحدهما." };
    entries.push({ item, weights, reps, rir, key: String(fd.get(`key_${k}`) ?? "").slice(0, 120), how: String(fd.get(`how_${k}`) ?? "") });
  }
  if (!entries.length) return { error: "ما فيه تمارين للحفظ. اربط تمريناً واحداً على الأقل." };
  try {
    await asTrainee(async (tx) => {
      for (const e of entries) {
        await tx.query("SELECT app.log_item_sets($1,$2,$3,$4,$5)", [e.item, week, e.weights, e.reps, e.rir]);
        if (e.key && e.how !== "alias" && e.how !== "name") {
          const ex = (await tx.query("SELECT exercise_id FROM block_items WHERE id = $1", [e.item])).rows[0]?.exercise_id;
          if (ex) await tx.query("SELECT app.save_exercise_alias($1,$2)", [e.key, ex]);
        }
      }
    });
  } catch (err) { return tFail(err); }
  const p = orderPath(fd); if (p) revalidatePath(p);
  return { ok: true, message: `تم حفظ ${entries.length} ${entries.length === 1 ? "تمرين" : "تمارين"} ✅` };
}

// ---------- حدود الجولات الأسبوعية لكل عضلة (للمدربة) ----------
export async function saveVolumeLimitsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const muscles = fd.getAll("muscle").map(String);
  const mins = fd.getAll("min").map(String), maxs = fd.getAll("max").map(String);
  const limits: Record<string, { min: number | null; max: number | null }> = {};
  const num = (v: string) => (v.trim() === "" ? null : Number(v));
  for (const [i, m] of muscles.entries()) {
    if (!m || m.length > 80) continue;
    const min = num(mins[i] ?? ""), max = num(maxs[i] ?? "");
    if (min == null && max == null) continue;
    if ((min != null && (!Number.isFinite(min) || min < 0 || min > 60)) || (max != null && (!Number.isFinite(max) || max < 0 || max > 60)))
      return { error: `الحدود بين 0 و 60 جولة (${m.split("/")[0].trim()}).` };
    if (min != null && max != null && min > max) return { error: `الحد الأدنى أكبر من الأعلى (${m.split("/")[0].trim()}).` };
    if (min === DEFAULT_VOLUME_LIMIT.min && max === DEFAULT_VOLUME_LIMIT.max) continue; // نفس الافتراضي، ما يحتاج حفظ
    limits[m] = { min, max };
  }
  try {
    await asCoach((tx, uid) => tx.query(
      `INSERT INTO site_settings (key, value, is_public, updated_by) VALUES ('volume_limits', $1, false, $2)
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`, [JSON.stringify(limits), uid]));
  } catch (err) { return { error: dbErrorMessage(err) ?? "تعذّر الحفظ." }; }
  revalidatePath("/admin/templates", "layout");
  revalidatePath("/admin/orders", "layout");
  return { ok: true, message: "تم حفظ الحدود." };
}

// ---------- فحص روابط فيديو التمارين (يوتيوب oEmbed: 200 يشتغل ويتضمّن في الموقع) ----------
export type VideoCheck = { ok?: number; total?: number; bad?: { id: string; name: string; url: string; reason: string }[]; error?: string };
export async function checkVideosAction(): Promise<VideoCheck> {
  let list: { id: string; name: string; video_url: string }[];
  try {
    list = await asCoach(async (tx) => (await tx.query(`SELECT id, name, video_url FROM exercises WHERE video_url IS NOT NULL AND video_url <> '' ORDER BY name`)).rows);
  } catch (err) { return { error: dbErrorMessage(err) ?? "للمدربة فقط." }; }
  const { youtubeId, tiktokId } = await import("@/lib/youtube");
  const bad: NonNullable<VideoCheck["bad"]> = [];
  const REASON: Record<number, string> = { 401: "ممنوع تشغيله داخل المواقع", 403: "خاص أو ممنوع تشغيله داخل المواقع", 404: "محذوف أو خاص", 400: "رابط غير صالح" };
  for (let i = 0; i < list.length; i += 12) {
    await Promise.all(list.slice(i, i + 12).map(async (e) => {
      if (tiktokId(e.video_url)) return; // تيك توك: لا يوجد فحص موثوق من الخادم
      const id = youtubeId(e.video_url);
      if (!id) { bad.push({ id: e.id, name: e.name, url: e.video_url, reason: "ليس رابط يوتيوب أو تيك توك كامل (يفتح خارج الموقع)" }); return; }
      try {
        const r = await fetch(`https://www.youtube.com/oembed?url=${encodeURIComponent(`https://www.youtube.com/watch?v=${id}`)}&format=json`, { signal: AbortSignal.timeout(6000), cache: "no-store" });
        if (!r.ok) bad.push({ id: e.id, name: e.name, url: e.video_url, reason: REASON[r.status] ?? `رد يوتيوب ${r.status}` });
      } catch {
        bad.push({ id: e.id, name: e.name, url: e.video_url, reason: "ما قدرنا نتحقق الآن (جرّبي لاحقاً)" });
      }
    }));
  }
  bad.sort((a, b) => a.name.localeCompare(b.name));
  return { ok: list.length - bad.length, total: list.length, bad };
}
