"use server";
import { revalidatePath } from "next/cache";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { loadCalorieState } from "@/lib/calorie-data";
import { profileFromIntake } from "@/lib/calorie-suggest";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاول مرة أخرى.";
const ORDER_NO = /^[A-Z]{2,5}-\d{6}-[A-Z0-9]{3,8}$/;
const PAFS = [1.0, 1.1, 1.2, 1.3, 1.4];
const s = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const n = (v: string) => {
  const t = v.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(",", ".");
  return t === "" ? null : Number(t);
};
const fail = (err: unknown): ActionState => {
  const m = (err as Error).message ?? "";
  if (m.startsWith("user:")) return { error: m.slice(5) };
  return { error: dbErrorMessage(err) ?? GENERIC };
};
const bad = (msg: string) => new Error(`user:${msg}`);

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await getCurrentUser();
  if (!u || u.role !== "coach") throw bad("للمدربة فقط.");
  return withUser(u.id, (tx) => fn(tx, u.id));
}
const orderOf = async (tx: Tx, orderNo: string) => {
  const { rows: [o] } = await tx.query(`SELECT id, user_id FROM orders WHERE order_no = $1`, [orderNo]);
  if (!o) throw bad("الطلب غير موجود.");
  return o as { id: string; user_id: string };
};

/** المتدرب: تحديث الطول والنشاط وأيام التمرين ومدته (الاقتراح يظهر للمدربة، والهدف لا يتغير إلا بموافقتها) */
export async function saveMyBodyInfoAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = s(fd, "order_no");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  const height = n(s(fd, "height")), paf = n(s(fd, "paf")), days = n(s(fd, "days")), minutes = n(s(fd, "minutes"));
  if (height != null && !(height >= 120 && height <= 230)) return { error: "الطول بين 120 و 230 سم." };
  if (paf == null || !PAFS.includes(paf)) return { error: "اختر مستوى نشاطك." };
  if (days == null || !Number.isInteger(days) || days < 0 || days > 7) return { error: "اختر أيام التمرين." };
  if (minutes == null || !Number.isInteger(minutes) || minutes < 0 || minutes > 240) return { error: "مدة التمرين بين 0 و 240 دقيقة." };
  try {
    await withUser(user.id, async (tx) => {
      const { rows: [o] } = await tx.query(`SELECT id FROM orders WHERE order_no = $1 AND user_id = $2`, [orderNo, user.id]);
      if (!o) throw bad("الطلب غير موجود.");
      const { rows: [i] } = await tx.query(`SELECT answers, health FROM intakes WHERE order_id = $1`, [o.id]);
      const seed = profileFromIntake(i?.answers, i?.health);
      await tx.query("SELECT app.update_my_calorie_profile($1,$2,$3,$4,$5,$6,$7,$8)",
        [orderNo, height, paf, days, minutes, seed.sex, seed.age, seed.eb_factor]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/account/orders/${orderNo}/progress`);
  return { ok: true, message: "تم حفظ بياناتك. المدربة تراجع أي تغيير في سعراتك قبل ما يتعدّل هدفك." };
}

/** المدربة: حفظ بيانات الحساب (المعادلة، نسبة الدهون، العمر، الجنس، الطول، النشاط، الأيام، المدة، الهدف) */
export async function saveCalorieProfileAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  try {
    const method = s(fd, "method");
    if (!["cunningham", "tenhaaf", "tinsley"].includes(method)) throw bad("اختاري طريقة الحساب.");
    const sex = s(fd, "sex") || null;
    if (sex && !["male", "female"].includes(sex)) throw bad("اختاري الجنس.");
    const age = n(s(fd, "age")), height = n(s(fd, "height")), bf = n(s(fd, "body_fat"));
    const paf = n(s(fd, "paf")), days = n(s(fd, "days")), minutes = n(s(fd, "minutes")), eb = n(s(fd, "eb_factor"));
    if (age != null && !(Number.isInteger(age) && age >= 10 && age <= 90)) throw bad("العمر بين 10 و 90.");
    if (height != null && !(height >= 120 && height <= 230)) throw bad("الطول بين 120 و 230 سم.");
    if (bf != null && !(bf >= 3 && bf <= 60)) throw bad("نسبة الدهون بين 3 و 60%.");
    if (method === "cunningham" && bf == null) throw bad("معادلة Cunningham تحتاج نسبة الدهون.");
    if (paf == null || !PAFS.includes(paf)) throw bad("اختاري مستوى النشاط.");
    if (days == null || !Number.isInteger(days) || days < 0 || days > 7) throw bad("أيام التمرين من 0 إلى 7.");
    if (minutes == null || !Number.isInteger(minutes) || minutes < 0 || minutes > 240) throw bad("مدة التمرين بين 0 و 240 دقيقة.");
    if (eb == null || eb < 0.6 || eb > 1.3) throw bad("اختاري الهدف.");
    await asCoach(async (tx, uid) => {
      const o = await orderOf(tx, orderNo);
      await tx.query(
        `INSERT INTO calorie_profiles (order_id, method, sex, age, height_cm, body_fat, paf, training_days, minutes, eb_factor, updated_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
         ON CONFLICT (order_id) DO UPDATE SET method=EXCLUDED.method, sex=EXCLUDED.sex, age=EXCLUDED.age, height_cm=EXCLUDED.height_cm,
           body_fat=EXCLUDED.body_fat, paf=EXCLUDED.paf, training_days=EXCLUDED.training_days, minutes=EXCLUDED.minutes,
           eb_factor=EXCLUDED.eb_factor, dismissed_kcal=NULL, updated_by=EXCLUDED.updated_by, updated_at=now()`,
        [o.id, method, sex, age, height, bf, paf, days, minutes, eb, uid]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  return { ok: true, message: "تم حفظ بيانات الحساب." };
}

/** المدربة: اعتماد السعرات المقترحة (يُعاد الحساب في الخادم؛ البروتين والدهون كما هي والكارب يتعدّل) */
export async function applyCalorieSuggestionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  let kcal = 0;
  try {
    await asCoach(async (tx, uid) => {
      const o = await orderOf(tx, orderNo);
      const st = await loadCalorieState(tx, o.id, o.user_id);
      const sg = st.suggestion;
      if (!sg) throw bad("ما فيه اقتراح حالياً.");
      kcal = sg.kcal;
      await tx.query(
        `INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat, updated_by, kcal_source, kcal_confirmed_at) VALUES ($1,$2,$3,$4,$5,$6,'coach',now())
         ON CONFLICT (order_id) DO UPDATE SET kcal=EXCLUDED.kcal, carbs=coalesce(EXCLUDED.carbs, nutrition_targets.carbs),
           updated_by=EXCLUDED.updated_by, updated_at=now(), kcal_source='coach', kcal_confirmed_at=now()`,
        [o.id, sg.kcal, sg.protein, sg.carbs, sg.fat, uid]);
      await tx.query("INSERT INTO admin_log (actor_id, action, target, details) VALUES ($1,'calories.apply',$2,$3)",
        [uid, orderNo, JSON.stringify({ from: st.target?.kcal ?? null, to: sg.kcal, carbs: sg.carbs, weight: sg.weight })]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  revalidatePath("/admin");
  return { ok: true, message: `تم اعتماد ${kcal.toLocaleString("en-US")} سعرة.` };
}

/** المدربة: تجاهل الاقتراح الحالي (لا يظهر نفس الرقم مرة ثانية) */
export async function dismissCalorieSuggestionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  try {
    await asCoach(async (tx, uid) => {
      const o = await orderOf(tx, orderNo);
      const st = await loadCalorieState(tx, o.id, o.user_id);
      if (!st.suggestion) throw bad("ما فيه اقتراح حالياً.");
      const p = st.profile;
      await tx.query(
        `INSERT INTO calorie_profiles (order_id, method, sex, age, height_cm, body_fat, paf, training_days, minutes, eb_factor, dismissed_kcal, updated_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
         ON CONFLICT (order_id) DO UPDATE SET dismissed_kcal = EXCLUDED.dismissed_kcal, updated_at = now()`,
        [o.id, p.method, p.sex, p.age, p.height_cm, p.body_fat, p.paf, p.training_days, p.minutes, p.eb_factor, st.suggestion.kcal, uid]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  revalidatePath("/admin");
  return { ok: true, message: "تم التجاهل. يظهر اقتراح جديد إذا تغيّرت بيانات المتدرب." };
}

/** المدربة: تأكيد السعرات المحسوبة تلقائياً (يُعاد الحساب في الخادم ويجب أن يطابق الرقم المعروض) */
export async function confirmAutoKcalAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = s(fd, "order_no");
  const shown = Number(s(fd, "kcal"));
  if (!ORDER_NO.test(orderNo)) return { error: GENERIC };
  try {
    await asCoach(async (tx, uid) => {
      const o = await orderOf(tx, orderNo);
      const r = await tx.query(
        `UPDATE nutrition_targets SET kcal_source = 'coach', kcal_confirmed_at = now(), updated_by = $3, updated_at = now()
          WHERE order_id = $1 AND kcal = $2 AND kcal_source = 'auto' AND kcal_confirmed_at IS NULL`, [o.id, shown, uid]);
      if (!r.rowCount) throw bad("تغيّرت الحسبة أو تأكدت من قبل. حدّثي الصفحة.");
      await tx.query("INSERT INTO admin_log (actor_id, action, target, details) VALUES ($1,'calories.confirm',$2,$3)",
        [uid, orderNo, JSON.stringify({ kcal: shown })]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}/nutrition`);
  revalidatePath(`/account/orders/${orderNo}/nutrition`);
  revalidatePath("/admin");
  return { ok: true, message: "تم تأكيد الحسبة." };
}
