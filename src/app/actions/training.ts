"use server";
// إجراءات منصة التدريب: مكتبة التمارين والقوالب والبلوك (المدربة)، والتسجيل والتبديل (المتدرب).
// كل إجراء يتحقق من الجلسة هنا، وقاعدة البيانات تتحقق مرة ثانية (RLS ودوال SECURITY DEFINER).

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
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
