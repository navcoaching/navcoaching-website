"use server";
// إجراءات منصة التدريب: مكتبة التمارين والقوالب والبلوك (المدربة)، والتسجيل والتبديل (المتدرب).
// كل إجراء يتحقق من الجلسة هنا، وقاعدة البيانات تتحقق مرة ثانية (RLS ودوال SECURITY DEFINER).

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { notifyTrainee, RESULT_LABEL, CHANNEL_LABEL, type ChannelResult } from "@/lib/notify";
import { parseReps, parseRir, type PlanWeek } from "@/lib/training";
import { EQUIPMENT, EX_STATUS, KINDS, LEVELS, MUSCLES, PATTERNS, SECONDARY_MUSCLES, placeFor } from "@/lib/exercises";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await getCurrentUser();
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
  status: z.enum(Object.keys(EX_STATUS) as [keyof typeof EX_STATUS]),
  video_url: opt(500).refine((v) => !v || /^https:\/\/\S+$/.test(v), "رابط الفيديو يجب أن يبدأ بـ https://"),
  instructions: opt(4000),
  notes: opt(4000),
  source: opt(120),
  source_name: opt(200),
  source_url: opt(500).refine((v) => !v || /^https?:\/\/\S+$/.test(v), "رابط المصدر غير صحيح."),
  alternatives: z.array(z.string().regex(UUID)).max(12, "الحد الأعلى 12 بديلاً."),
});

export async function saveExerciseAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const g = (k: string) => String(fd.get(k) ?? "");
  const parsed = exerciseSchema.safeParse({
    id: g("id"), name: g("name"), primary_muscle: g("primary_muscle"), secondary: fd.getAll("secondary").map(String),
    pattern: g("pattern"), kind: g("kind"), equipment: g("equipment"), level: g("level"), status: g("status"),
    video_url: g("video_url"), instructions: g("instructions"), notes: g("notes"),
    source: g("source"), source_name: g("source_name"), source_url: g("source_url"),
    alternatives: [...new Set(fd.getAll("alt").map(String))],
  });
  if (!parsed.success) return { error: parsed.error.issues[0].message };
  const v = parsed.data;
  let id = v.id;
  try {
    await asCoach(async (tx, uid) => {
      const cols = [v.name, v.primary_muscle, v.secondary.filter((m) => m !== v.primary_muscle), v.pattern, v.kind, v.equipment, v.level,
        placeFor(v.equipment), v.video_url, v.instructions, v.notes, v.source, v.source_name, v.source_url, v.status];
      if (id) {
        const r = await tx.query(
          `UPDATE exercises SET name=$2, primary_muscle=$3, secondary_muscles=$4, pattern=$5, kind=$6, equipment=$7, level=$8, place=$9,
             video_url=$10, instructions=$11, notes=$12, source=$13, source_name=$14, source_url=$15, status=$16, updated_at=now()
           WHERE id=$1`, [id, ...cols]);
        if (r.rowCount === 0) throw new Error("التمرين غير موجود.");
      } else {
        id = (await tx.query(
          `INSERT INTO exercises (name, primary_muscle, secondary_muscles, pattern, kind, equipment, level, place,
             video_url, instructions, notes, source, source_name, source_url, status)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING id`, cols)).rows[0].id;
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
const trainingFail = (err: unknown): ActionState =>
  (err as Error).message === "gone" ? { error: "العنصر غير موجود، حدّثي الصفحة." } : fail(err);

const templateSchema = z.object({
  id: z.string().refine((v) => v === "" || UUID.test(v)),
  name: z.string().trim().min(2, "اكتبي اسم القالب.").max(120),
  weeks: z.coerce.number().int().min(1).max(12, "عدد الأسابيع من 1 إلى 12."),
  instructions: opt(4000),
  archived: z.boolean(),
});

export async function saveTemplateAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const g = (k: string) => String(fd.get(k) ?? "");
  const p = templateSchema.safeParse({ id: g("id"), name: g("name"), weeks: g("weeks") || "5", instructions: g("instructions"), archived: fd.get("archived") === "on" });
  if (!p.success) return { error: p.error.issues[0].message };
  const v = p.data;
  let id = v.id;
  try {
    await asCoach(async (tx) => {
      if (id) {
        const r = await tx.query(`UPDATE program_templates SET name=$2, weeks=$3, instructions=$4, archived=$5, updated_at=now() WHERE id=$1`,
          [id, v.name, v.weeks, v.instructions, v.archived]);
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
  const reps = parseReps(String(fd.get("reps") ?? ""));
  const rir = parseRir(String(fd.get("rir") ?? ""));
  if (!name) return { error: "اختاري التمرين من القائمة." };
  if (reps === null) return { error: "اكتبي المجموعات والتكرارات مثل 3x12 أو 12-10-8." };
  if (rir === undefined) return { error: "RIR رقم من 0 إلى 10." };
  const t = T[kind];
  try {
    const res = await asCoach(async (tx) => {
      const o = await ownerOfDay(tx, kind, day);
      const ex = await exerciseByName(tx, name);
      if (!ex) return { error: "التمرين غير موجود في المكتبة أو غير معتمد. اختاريه من القائمة." };
      const plan: PlanWeek[] = Array.from({ length: o.weeks }, () => ({ sets: reps.length, reps, rir }));
      const { rows: [{ pos }] } = await tx.query(`SELECT coalesce(max(position), -1) + 1 AS pos FROM ${t.items} WHERE day_id = $1`, [day]);
      if (kind === "block") {
        await tx.query(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) VALUES ($1,$2,$3,$3,$4)`, [day, pos, ex, JSON.stringify(plan)]);
      } else {
        await tx.query(`INSERT INTO template_items (day_id, position, exercise_id, plan) VALUES ($1,$2,$3,$4)`, [day, pos, ex, JSON.stringify(plan)]);
      }
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
  const note = String(fd.get("note") ?? "").trim();
  if (!name) return { error: "اختاري التمرين من القائمة." };
  if (note.length > 500) return { error: "الملاحظة حتى 500 حرف." };
  const copyFirst = fd.get("copy_first") === "on";
  const t = T[kind];
  try {
    const res = await asCoach(async (tx) => {
      const o = await ownerOfItem(tx, kind, item);
      const { rows: [cur] } = await tx.query(`SELECT exercise_id FROM ${t.items} WHERE id = $1`, [item]);
      const ex = await exerciseByName(tx, name, cur.exercise_id);
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
  return { ok: true, message: "تم إسناد البرنامج." + summarize(results) };
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
  const p = blockSchema.safeParse({ id: g("id"), name: g("name"), start_date: g("start_date"), weeks: g("weeks"), steps_goal_week: g("steps_goal_week") || "0", instructions: g("instructions") });
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
