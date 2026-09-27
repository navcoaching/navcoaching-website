"use server";
// إجراءات التغذية والمكملات: الأهداف، الجداول الغذائية (قوالب ونسخ المتدربين)، روتين المكملات، وسجل الأكل اليومي.
// الجلسة تُفحص هنا، وقاعدة البيانات تتحقق مرة ثانية (RLS ودوال SECURITY DEFINER).

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { MEAL_KINDS } from "@/lib/nutrition";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ORDER_NO = /^[A-Z]{2,5}-\d{6}-[A-Z0-9]{3,8}$/;

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await getCurrentUser();
  if (!u || u.role !== "coach") throw new Error("forbidden");
  return withUser(u.id, (tx) => fn(tx, u.id));
}
const fail = (err: unknown): ActionState => {
  const m = (err as Error).message;
  if (m === "forbidden") return { error: "لا تملكين صلاحية." };
  if (m === "gone") return { error: "العنصر غير موجود، حدّثي الصفحة." };
  if (m.startsWith("user:")) return { error: m.slice(5) };
  return { error: dbErrorMessage(err) ?? GENERIC };
};
const bad = (msg: string) => new Error(`user:${msg}`);
const s = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const id = (fd: FormData, k: string) => { const v = s(fd, k); return UUID.test(v) ? v : null; };
const toNum = (v: string) => {
  const t = v.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(",", ".").trim();
  return t === "" ? null : Number(t);
};
const text = (v: string, max: number, label: string) => {
  if (v.length > max) throw bad(`${label}: الحد الأعلى ${max} حرف.`);
  return v || null;
};
const macro = (fd: FormData, k: string, label: string, max: number) => {
  const n = toNum(s(fd, k));
  if (n == null) return 0;
  if (!Number.isFinite(n) || n < 0 || n > max) throw bad(`${label} رقم بين 0 و ${max}.`);
  return Math.round(n * 10) / 10;
};
const kindOf = (v: string) => (v in MEAL_KINDS ? v : null);

/** يحدّث صفحات الجدول/الروتين والمتدرب المرتبط به */
async function revalidateFor(tx: Tx, table: "nutrition_plans" | "supplement_routines", ownerId: string) {
  const { rows: [r] } = await tx.query(`SELECT o.order_no FROM ${table} t LEFT JOIN orders o ON o.id = t.order_id WHERE t.id = $1`, [ownerId]);
  revalidatePath("/admin/nutrition");
  revalidatePath(table === "nutrition_plans" ? `/admin/nutrition/plans/${ownerId}` : `/admin/nutrition/supplements/${ownerId}`);
  if (r?.order_no) { revalidatePath(`/admin/orders/${r.order_no}/nutrition`); revalidatePath(`/account/orders/${r.order_no}/nutrition`); }
}
async function planOfMeal(tx: Tx, meal: string) {
  const { rows: [r] } = await tx.query(`SELECT plan_id FROM plan_meals WHERE id = $1`, [meal]);
  if (!r) throw new Error("gone");
  return r.plan_id as string;
}
async function planOfItem(tx: Tx, item: string) {
  const { rows: [r] } = await tx.query(`SELECT m.plan_id, i.meal_id FROM plan_items i JOIN plan_meals m ON m.id = i.meal_id WHERE i.id = $1`, [item]);
  if (!r) throw new Error("gone");
  return r as { plan_id: string; meal_id: string };
}
async function routineOfSection(tx: Tx, section: string) {
  const { rows: [r] } = await tx.query(`SELECT routine_id FROM supplement_sections WHERE id = $1`, [section]);
  if (!r) throw new Error("gone");
  return r.routine_id as string;
}
async function routineOfItem(tx: Tx, item: string) {
  const { rows: [r] } = await tx.query(`SELECT s.routine_id FROM supplement_items i JOIN supplement_sections s ON s.id = i.section_id WHERE i.id = $1`, [item]);
  if (!r) throw new Error("gone");
  return r.routine_id as string;
}
/** إعادة ترتيب عنصر لأعلى/لأسفل داخل مجموعته */
async function move(tx: Tx, table: string, groupCol: string, itemId: string, dir: number) {
  const { rows: [g] } = await tx.query(`SELECT ${groupCol} AS g FROM ${table} WHERE id = $1`, [itemId]);
  if (!g) throw new Error("gone");
  const ids = (await tx.query(`SELECT id FROM ${table} WHERE ${groupCol} = $1 ORDER BY position, id`, [g.g])).rows.map((r) => r.id as string);
  const i = ids.indexOf(itemId), j = i + dir;
  if (j < 0 || j >= ids.length) return;
  [ids[i], ids[j]] = [ids[j], ids[i]];
  await tx.query(`UPDATE ${table} SET position = x.ord - 1 FROM unnest($1::uuid[]) WITH ORDINALITY AS x(id, ord) WHERE ${table}.id = x.id`, [ids]);
}

// =====================================================================
// الأهداف اليومية للمتدرب
// =====================================================================
export async function saveTargetsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  try {
    const kcal = toNum(s(fd, "kcal"));
    if (kcal != null && (!Number.isInteger(kcal) || kcal < 500 || kcal > 10000)) throw bad("السعرات رقم صحيح بين 500 و 10000.");
    const vals = [kcal, macro(fd, "protein", "البروتين", 1000), macro(fd, "carbs", "الكارب", 1500), macro(fd, "fat", "الدهون", 500)];
    const rules = text(s(fd, "rules"), 5000, "القواعد");
    await asCoach(async (tx, uid) => {
      const { rows: [o] } = await tx.query(`SELECT id FROM orders WHERE order_no = $1`, [orderNo]);
      if (!o) throw new Error("gone");
      await tx.query(
        `INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat, rules, updated_by) VALUES ($1,$2,$3,$4,$5,$6,$7)
         ON CONFLICT (order_id) DO UPDATE SET kcal=EXCLUDED.kcal, protein=EXCLUDED.protein, carbs=EXCLUDED.carbs, fat=EXCLUDED.fat,
           rules=EXCLUDED.rules, updated_by=EXCLUDED.updated_by, updated_at=now()`,
        [o.id, ...vals, rules, uid]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  return { ok: true, message: "تم حفظ الأهداف." };
}

// =====================================================================
// الجداول الغذائية (القالب والنسخة بنفس المحرر)
// =====================================================================
export async function savePlanAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const planId = id(fd, "id");
  let newId = "";
  try {
    const name = s(fd, "name");
    if (!name || name.length > 120) throw bad("اكتبي اسم الجدول (حتى 120 حرفاً).");
    const notes = text(s(fd, "notes"), 3000, "الملاحظات");
    const archived = fd.get("archived") === "on";
    await asCoach(async (tx) => {
      if (planId) {
        const r = await tx.query(`UPDATE nutrition_plans SET name=$2, notes=$3, archived=$4, updated_at=now() WHERE id=$1`, [planId, name, notes, archived]);
        if (!r.rowCount) throw new Error("gone");
        await revalidateFor(tx, "nutrition_plans", planId);
      } else {
        newId = (await tx.query(`INSERT INTO nutrition_plans (name, notes) VALUES ($1,$2) RETURNING id`, [name, notes])).rows[0].id;
      }
    });
  } catch (err) {
    if ((err as { code?: string }).code === "23505") return { error: "يوجد قالب بنفس الاسم." };
    return fail(err);
  }
  if (newId) { revalidatePath("/admin/nutrition"); redirect(`/admin/nutrition/plans/${newId}?created=1`); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deletePlanAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const planId = id(fd, "id");
  if (!planId) return { error: GENERIC };
  let back = "/admin/nutrition";
  try {
    await asCoach(async (tx) => {
      const { rows: [p] } = await tx.query(`SELECT o.order_no FROM nutrition_plans p LEFT JOIN orders o ON o.id = p.order_id WHERE p.id = $1`, [planId]);
      if (!p) throw new Error("gone");
      await tx.query(`DELETE FROM nutrition_plans WHERE id = $1`, [planId]);
      if (p.order_no) { back = `/admin/orders/${p.order_no}/nutrition`; revalidatePath(`/account/orders/${p.order_no}/nutrition`); }
    });
  } catch (err) { return fail(err); }
  revalidatePath(back);
  redirect(back);
}

export async function addMealAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const planId = id(fd, "plan");
  const kind = kindOf(s(fd, "kind"));
  const title = s(fd, "title");
  if (!planId) return { error: GENERIC };
  if (!kind) return { error: "اختاري نوع الوجبة." };
  if (!title || title.length > 120) return { error: "اكتبي اسم الوجبة (حتى 120 حرفاً)." };
  try {
    await asCoach(async (tx) => {
      await tx.query(
        `INSERT INTO plan_meals (plan_id, kind, title, position) SELECT $1, $2, $3, coalesce(max(position), -1) + 1 FROM plan_meals WHERE plan_id = $1`,
        [planId, kind, title]);
      await revalidateFor(tx, "nutrition_plans", planId);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تمت إضافة الوجبة." };
}

export async function saveMealAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const meal = id(fd, "meal");
  const kind = kindOf(s(fd, "kind"));
  const title = s(fd, "title");
  if (!meal) return { error: GENERIC };
  if (!kind) return { error: "اختاري نوع الوجبة." };
  if (!title || title.length > 120) return { error: "اكتبي اسم الوجبة (حتى 120 حرفاً)." };
  try {
    const method = text(s(fd, "method"), 3000, "الطريقة");
    await asCoach(async (tx) => {
      const plan = await planOfMeal(tx, meal);
      await tx.query(`UPDATE plan_meals SET kind=$2, title=$3, method=$4 WHERE id=$1`, [meal, kind, title, method]);
      await revalidateFor(tx, "nutrition_plans", plan);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deleteMealAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const meal = id(fd, "meal");
  if (!meal) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const plan = await planOfMeal(tx, meal);
      await tx.query(`DELETE FROM plan_meals WHERE id = $1`, [meal]);
      await revalidateFor(tx, "nutrition_plans", plan);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحذف." };
}

export async function moveMealAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const meal = id(fd, "meal");
  if (!meal) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const plan = await planOfMeal(tx, meal);
      await move(tx, "plan_meals", "plan_id", meal, fd.get("dir") === "up" ? -1 : 1);
      await revalidateFor(tx, "nutrition_plans", plan);
    });
  } catch (err) { return fail(err); }
  return { ok: true };
}

function foodFields(fd: FormData) {
  const food = s(fd, "food");
  if (!food || food.length > 160) throw bad("اكتبي اسم المكوّن (حتى 160 حرفاً).");
  return [food, text(s(fd, "portion"), 80, "الوزن/الحصة"), macro(fd, "protein", "البروتين", 500), macro(fd, "carbs", "الكارب", 500), macro(fd, "fat", "الدهون", 300)] as const;
}

export async function addFoodAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const meal = id(fd, "meal");
  if (!meal) return { error: GENERIC };
  try {
    const f = foodFields(fd);
    await asCoach(async (tx) => {
      const plan = await planOfMeal(tx, meal);
      await tx.query(
        `INSERT INTO plan_items (meal_id, food, portion, protein, carbs, fat, position)
         SELECT $1,$2,$3,$4,$5,$6, coalesce(max(position), -1) + 1 FROM plan_items WHERE meal_id = $1`, [meal, ...f]);
      await revalidateFor(tx, "nutrition_plans", plan);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تمت الإضافة." };
}

export async function saveFoodAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const item = id(fd, "item");
  if (!item) return { error: GENERIC };
  try {
    const f = foodFields(fd);
    await asCoach(async (tx) => {
      const { plan_id } = await planOfItem(tx, item);
      await tx.query(`UPDATE plan_items SET food=$2, portion=$3, protein=$4, carbs=$5, fat=$6 WHERE id=$1`, [item, ...f]);
      await revalidateFor(tx, "nutrition_plans", plan_id);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deleteFoodAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const item = id(fd, "item");
  if (!item) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const { plan_id } = await planOfItem(tx, item);
      await tx.query(`DELETE FROM plan_items WHERE id = $1`, [item]);
      await revalidateFor(tx, "nutrition_plans", plan_id);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحذف." };
}

export async function assignNutritionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  const tpl = id(fd, "template");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  if (!tpl) return { error: "اختاري الجدول." };
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_assign_nutrition($1,$2)", [orderNo, tpl]));
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  return { ok: true, message: "تمت إضافة الجدول للمتدرب. تقدرين تعدّلين نسخته بدون ما يتأثر القالب." };
}

// =====================================================================
// روتين المكملات
// =====================================================================
export async function saveRoutineAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const rid = id(fd, "id");
  let newId = "";
  try {
    const name = s(fd, "name");
    if (!name || name.length > 120) throw bad("اكتبي اسم الروتين (حتى 120 حرفاً).");
    const intro = text(s(fd, "intro"), 2000, "المقدمة");
    await asCoach(async (tx) => {
      if (rid) {
        const r = await tx.query(`UPDATE supplement_routines SET name=$2, intro=$3, updated_at=now() WHERE id=$1`, [rid, name, intro]);
        if (!r.rowCount) throw new Error("gone");
        await revalidateFor(tx, "supplement_routines", rid);
      } else {
        newId = (await tx.query(`INSERT INTO supplement_routines (name, intro) VALUES ($1,$2) RETURNING id`, [name, intro])).rows[0].id;
      }
    });
  } catch (err) {
    if ((err as { code?: string }).code === "23505") return { error: "يوجد روتين بنفس الاسم." };
    return fail(err);
  }
  if (newId) { revalidatePath("/admin/nutrition"); redirect(`/admin/nutrition/supplements/${newId}?created=1`); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deleteRoutineAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const rid = id(fd, "id");
  if (!rid) return { error: GENERIC };
  let back = "/admin/nutrition";
  try {
    await asCoach(async (tx) => {
      const { rows: [r] } = await tx.query(`SELECT o.order_no FROM supplement_routines r LEFT JOIN orders o ON o.id = r.order_id WHERE r.id = $1`, [rid]);
      if (!r) throw new Error("gone");
      await tx.query(`DELETE FROM supplement_routines WHERE id = $1`, [rid]);
      if (r.order_no) { back = `/admin/orders/${r.order_no}/nutrition`; revalidatePath(`/account/orders/${r.order_no}/nutrition`); }
    });
  } catch (err) { return fail(err); }
  revalidatePath(back);
  redirect(back);
}

export async function addSectionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const rid = id(fd, "routine");
  const title = s(fd, "title");
  if (!rid) return { error: GENERIC };
  if (!title || title.length > 120) return { error: "اكتبي عنوان القسم (حتى 120 حرفاً)." };
  try {
    await asCoach(async (tx) => {
      await tx.query(
        `INSERT INTO supplement_sections (routine_id, title, position) SELECT $1, $2, coalesce(max(position), -1) + 1 FROM supplement_sections WHERE routine_id = $1`,
        [rid, title]);
      await revalidateFor(tx, "supplement_routines", rid);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تمت إضافة القسم." };
}

export async function saveSectionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const sec = id(fd, "section");
  const title = s(fd, "title");
  if (!sec) return { error: GENERIC };
  if (!title || title.length > 120) return { error: "اكتبي عنوان القسم (حتى 120 حرفاً)." };
  try {
    const routine = text(s(fd, "routine"), 4000, "الروتين");
    await asCoach(async (tx) => {
      const rid = await routineOfSection(tx, sec);
      await tx.query(`UPDATE supplement_sections SET title=$2, routine=$3 WHERE id=$1`, [sec, title, routine]);
      await revalidateFor(tx, "supplement_routines", rid);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deleteSectionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const sec = id(fd, "section");
  if (!sec) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const rid = await routineOfSection(tx, sec);
      await tx.query(`DELETE FROM supplement_sections WHERE id = $1`, [sec]);
      await revalidateFor(tx, "supplement_routines", rid);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحذف." };
}

function suppFields(fd: FormData) {
  const name = s(fd, "name");
  if (!name || name.length > 120) throw bad("اكتبي اسم المكمل (حتى 120 حرفاً).");
  const link = s(fd, "link");
  if (link && !/^https:\/\/\S+$/.test(link)) throw bad("الرابط يجب أن يبدأ بـ https://");
  return [name, text(s(fd, "dose"), 120, "الجرعة"), text(s(fd, "timing"), 160, "التوقيت"), text(s(fd, "importance"), 60, "الأهمية"),
    text(s(fd, "benefit"), 1000, "الفائدة"), link || null] as const;
}

export async function addSuppAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const sec = id(fd, "section");
  if (!sec) return { error: GENERIC };
  try {
    const f = suppFields(fd);
    await asCoach(async (tx) => {
      const rid = await routineOfSection(tx, sec);
      await tx.query(
        `INSERT INTO supplement_items (section_id, name, dose, timing, importance, benefit, link, position)
         SELECT $1,$2,$3,$4,$5,$6,$7, coalesce(max(position), -1) + 1 FROM supplement_items WHERE section_id = $1`, [sec, ...f]);
      await revalidateFor(tx, "supplement_routines", rid);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تمت الإضافة." };
}

export async function saveSuppAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const item = id(fd, "item");
  if (!item) return { error: GENERIC };
  try {
    const f = suppFields(fd);
    await asCoach(async (tx) => {
      const rid = await routineOfItem(tx, item);
      await tx.query(`UPDATE supplement_items SET name=$2, dose=$3, timing=$4, importance=$5, benefit=$6, link=$7 WHERE id=$1`, [item, ...f]);
      await revalidateFor(tx, "supplement_routines", rid);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحفظ." };
}

export async function deleteSuppAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const item = id(fd, "item");
  if (!item) return { error: GENERIC };
  try {
    await asCoach(async (tx) => {
      const rid = await routineOfItem(tx, item);
      await tx.query(`DELETE FROM supplement_items WHERE id = $1`, [item]);
      await revalidateFor(tx, "supplement_routines", rid);
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "تم الحذف." };
}

export async function assignSupplementsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  const tpl = id(fd, "template");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  if (!tpl) return { error: "اختاري الروتين." };
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_assign_supplements($1,$2)", [orderNo, tpl]));
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  return { ok: true, message: "تم إسناد روتين المكملات للمتدرب." };
}

// =====================================================================
// المتدرب: سجل الأكل اليومي (من وجبات جداوله أو إدخال حر)
// =====================================================================
const T_GENERIC = "تعذّر الحفظ. حاول مرة أخرى.";
export async function logFoodAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const u = await getCurrentUser();
  if (!u) return { error: "سجّل الدخول أولاً." };
  const orderNo = s(fd, "order_no");
  const date = s(fd, "date");
  const kind = kindOf(s(fd, "kind"));
  const meal = id(fd, "meal");
  if (!ORDER_NO.test(orderNo) || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return { error: T_GENERIC };
  if (!kind) return { error: "اختر الوجبة (فطور، غداء، عشاء، سناك)." };
  try {
    let name: string | null = null, p = 0, c = 0, f = 0;
    if (!meal) {
      name = s(fd, "name");
      if (!name) throw bad("اكتب اسم الأكلة أو اختر وجبة من جدولك.");
      if (name.length > 160) throw bad("اسم الأكلة طويل.");
      p = macro(fd, "protein", "البروتين", 500); c = macro(fd, "carbs", "الكارب", 500); f = macro(fd, "fat", "الدهون", 300);
    }
    await withUser(u.id, (tx) => tx.query("SELECT app.log_food($1,$2,$3,$4,$5,$6,$7,$8)", [orderNo, date, kind, meal, name, p, c, f]));
  } catch (err) {
    const m = (err as Error).message;
    return { error: m.startsWith("user:") ? m.slice(5) : dbErrorMessage(err) ?? T_GENERIC };
  }
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  return { ok: true, message: "تمت الإضافة ✅" };
}

export async function deleteFoodLogAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const u = await getCurrentUser();
  if (!u) return { error: "سجّل الدخول أولاً." };
  const logId = Number(fd.get("id"));
  const orderNo = s(fd, "order_no");
  if (!Number.isSafeInteger(logId) || !ORDER_NO.test(orderNo)) return { error: T_GENERIC };
  try {
    await withUser(u.id, (tx) => tx.query("SELECT app.delete_food_log($1)", [logId]));
  } catch (err) { return { error: dbErrorMessage(err) ?? T_GENERIC }; }
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  return { ok: true, message: "تم الحذف." };
}
