"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { dbErrorMessage, withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { profileSchema, splitProfile } from "@/lib/profile";
import { allow } from "@/lib/rate";
import { cleanUpload, newKey, UploadError } from "@/lib/uploads";
import { storage } from "@/lib/storage";
import { notifySafe } from "@/lib/mail";
import { validStartPref } from "@/lib/schedule";
import { createRenewal } from "@/lib/renew";
import { createOrder } from "@/lib/create-order";

export type ActionState = { ok?: boolean; message?: string; error?: string; fieldErrors?: Record<string, string> };

const LIMITED = "محاولات كثيرة خلال وقت قصير. انتظر قليلاً ثم حاول مرة أخرى.";
const GENERIC = "حدث خطأ غير متوقع. حاول مرة أخرى أو تواصل معنا على واتساب.";

function formToObject(fd: FormData) {
  const o: Record<string, unknown> = {};
  for (const key of new Set(fd.keys())) {
    if (key.startsWith("$ACTION")) continue;
    o[key] = key === "equip" ? fd.getAll(key) : fd.get(key);
  }
  return o;
}

// ---------- إنشاء الطلب مع الاستبيان ----------
export async function createOrderAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "انتهت الجلسة. سجّل الدخول مرة أخرى ثم أعد الإرسال (إجاباتك محفوظة على جهازك)." };
  const r = await createOrder(user.id, fd);
  if ("error" in r) return r;
  redirect(`/account/orders/${r.orderNo}?new=1`);
}

// ---------- رفع إيصال التحويل ----------
export async function uploadProofAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  if (!(await allow(`proof:u:${user.id}`, 10, 3600))) return { error: LIMITED };

  // تحقق مبكر من الملكية والحالة قبل حفظ أي ملف
  const order = await withUser(user.id, async (tx) =>
    (await tx.query("SELECT status FROM orders WHERE order_no = $1 AND user_id = $2", [orderNo, user.id])).rows[0]);
  if (!order) return { error: "الطلب غير موجود." };
  if (order.status !== "awaiting_payment") return { error: "لا يمكن رفع إيصال في حالة الطلب الحالية." };

  let file;
  try {
    file = await cleanUpload(fd.get("proof") as File | null, "proof");
  } catch (err) {
    return { error: err instanceof UploadError ? err.message : GENERIC };
  }
  const key = newKey("proofs", file.ext);
  const store = await storage();
  await store.put(key, file.data, file.mime);
  try {
    await withUser(user.id, (tx) => tx.query("SELECT app.submit_payment_proof($1,$2,$3,$4,$5)", [orderNo, key, file.mime, file.size, file.sha256]));
  } catch (err) {
    await store.remove(key);
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, `إيصال جديد للطلب ${orderNo}`, `رُفع إيصال تحويل للطلب ${orderNo}.\nتأكدي من وصول المبلغ في كشف الحساب قبل الاعتماد.`);
  revalidatePath(`/account/orders/${orderNo}`);
  return { ok: true, message: "وصلنا الإيصال. نراجع التحويل ونحدّث حالة طلبك بعد التأكد من وصول المبلغ." };
}

// ---------- إلغاء قبل الدفع ----------
export async function cancelOrderAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  try {
    await withUser(user.id, (tx) => tx.query("SELECT app.client_cancel($1)", [orderNo]));
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  revalidatePath(`/account/orders/${orderNo}`);
  return { ok: true, message: "تم إلغاء الطلب." };
}

// ---------- المراجعة الأسبوعية ----------
export async function submitCheckinAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  const topics = fd.getAll("topic").map(String);
  const questions = fd.getAll("q").map(String);
  const answers = fd.getAll("a").map((a) => String(a).trim().slice(0, 1000));
  if (answers.length === 0 || answers.length !== questions.length || answers.every((a) => !a)) return { error: "اكتب إجاباتك قبل الإرسال." };
  if (!(await allow(`checkin:u:${user.id}`, 10, 3600))) return { error: LIMITED };
  const payload = questions.slice(0, 20).map((q, i) => ({ topic: topics[i]?.slice(0, 60) ?? "", q: q.slice(0, 200), a: answers[i] }));
  try {
    await withUser(user.id, (tx) => tx.query("SELECT app.submit_checkin($1,$2)", [orderNo, JSON.stringify(payload)]));
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, `مراجعة أسبوعية جديدة — ${orderNo}`, `وصلت مراجعة أسبوعية جديدة للطلب ${orderNo}. التفاصيل في لوحة الإدارة.`);
  revalidatePath(`/account/orders/${orderNo}`);
  return { ok: true, message: "وصلت مراجعتك. بيوصلك رد المدربة هنا." };
}

// ---------- التقييم (تقييم الخدمة بعد التجربة، غير الاستبيان) ----------
const reviewSchema = z.object({
  order_no: z.string().min(5).max(40),
  rating: z.union([z.literal(""), z.coerce.number().int().min(1).max(5)]).optional().default(""),
  body: z.string().trim().min(10, "اكتب تجربتك (10 أحرف على الأقل).").max(1500, "النص أطول من 1500 حرف."),
  display_mode: z.enum(["full", "first", "anon"], { message: "اختر طريقة ظهور اسمك." }),
  consent: z.enum(["", "on"]).optional().default(""),
});

export async function submitReviewAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const parsed = reviewSchema.safeParse(formToObject(fd));
  if (!parsed.success) {
    const fieldErrors: Record<string, string> = {};
    for (const issue of parsed.error.issues) fieldErrors[String(issue.path[0])] ??= issue.message;
    return { error: "راجع الحقول المحددة.", fieldErrors };
  }
  const v = parsed.data;
  if (!(await allow(`review:u:${user.id}`, 5, 3600))) return { error: LIMITED };
  try {
    await withUser(user.id, (tx) =>
      tx.query("SELECT app.submit_review($1,$2,$3,$4,$5)", [v.order_no, v.rating === "" ? null : v.rating, v.body, v.display_mode, v.consent === "on"]));
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, "تقييم جديد بانتظار المراجعة", "وصل تقييم جديد من متدرب. راجعيه من لوحة الإدارة قبل النشر.");
  revalidatePath(`/account/orders/${v.order_no}`);
  return { ok: true, message: "شكراً لك! وصل تقييمك، ويظهر للعامة بعد المراجعة إذا وافقت على النشر." };
}

// ---------- تحديث الاسم ----------
export async function updateProfileAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const name = String(fd.get("name") ?? "").trim();
  if (name.length < 2 || name.length > 80) return { fieldErrors: { name: "اكتب اسمك (حرفين على الأقل)." } };
  await withUser(user.id, (tx) => tx.query(`UPDATE "user" SET name = $1, "updatedAt" = now() WHERE id = $2`, [name, user.id]));
  revalidatePath("/account");
  return { ok: true, message: "تم حفظ الاسم." };
}

// ---------- تفضيلات التواصل (البريد / واتساب) ----------
export async function savePrefsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const email = fd.get("email_enabled") === "on";
  const whatsapp = fd.get("whatsapp_enabled") === "on";
  // خيار إشعارات الجوال يظهر فقط عند تفعيلها في الموقع؛ بدونه تبقى القيمة كما هي
  const push = fd.get("push_field") === "1" ? fd.get("push_enabled") === "on" : null;
  await withUser(user.id, (tx) => tx.query(
    `INSERT INTO user_prefs (user_id, email_enabled, whatsapp_enabled, push_enabled) VALUES ($1,$2,$3,coalesce($4, true))
     ON CONFLICT (user_id) DO UPDATE SET email_enabled = EXCLUDED.email_enabled, whatsapp_enabled = EXCLUDED.whatsapp_enabled,
       push_enabled = coalesce($4, user_prefs.push_enabled), updated_at = now()`,
    [user.id, email, whatsapp, push]));
  revalidatePath("/account");
  return { ok: true, message: "تم حفظ تفضيلات التواصل." };
}

// ---------- استكمال الوزن والطول للاستبيانات القديمة ----------
export async function updateMeasurementsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  const weight = Number(fd.get("weight")), height = Number(fd.get("height"));
  const fieldErrors: Record<string, string> = {};
  if (!Number.isFinite(weight) || weight < 30 || weight > 250) fieldErrors.weight = "اكتب وزناً بين 30 و 250 كغ.";
  if (!Number.isFinite(height) || height < 120 || height > 230) fieldErrors.height = "اكتب طولاً بين 120 و 230 سم.";
  if (Object.keys(fieldErrors).length) return { error: "راجع الحقول المحددة.", fieldErrors };
  if (!(await allow(`measure:u:${user.id}`, 10, 3600))) return { error: LIMITED };
  try {
    await withUser(user.id, (tx) => tx.query("SELECT app.update_intake_measurements($1,$2,$3)", [orderNo, weight, height]));
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  revalidatePath(`/account/orders/${orderNo}`);
  return { ok: true, message: "شكراً! تم تحديث القياسات." };
}

// ---------- طلب جدول مجاني ----------
export type FreePlanState = ActionState & { owned?: boolean; needLogin?: boolean };
export async function requestFreePlanAction(_: FreePlanState, fd: FormData): Promise<FreePlanState> {
  const slug = String(fd.get("slug") ?? "");
  if (!/^[a-z0-9-]{1,60}$/.test(slug)) return { error: GENERIC };
  const user = await getCurrentUser();
  if (!user) return { needLogin: true, error: "انتهت الجلسة. سجّل الدخول ثم اطلب الجدول مرة أخرى." };
  if (!(await allow(`freeplan:u:${user.id}`, 30, 3600))) return { error: LIMITED };
  try {
    const { rows: [r] } = await withUser(user.id, (tx) => tx.query("SELECT app.request_free_plan($1) AS r", [slug]));
    revalidatePath("/account");
    return r.r.created
      ? { ok: true, owned: true, message: "تم! أُضيف الجدول إلى «جداولي المجانية» في حسابك، وتقدر تحمّله الآن." }
      : { ok: true, owned: true, message: "هذا الجدول موجود في جداولي مسبقاً." };
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
}

// ---------- تجديد الاشتراك بخصم (آخر 5 أيام) ----------
export async function renewAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const r = await createRenewal(user.id, String(fd.get("order_no") ?? ""));
  if ("error" in r) return { error: r.error };
  revalidatePath("/account");
  redirect(`/account/orders/${r.no}?renewed=1`);
}

// ---------- استبيان نهاية البرنامج (للمدربة فقط، غير منشور) ----------
export async function submitExitSurveyAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  const wants = fd.get("wants_renewal");
  const reason = String(fd.get("reason") ?? "").trim();
  const experience = String(fd.get("experience") ?? "").trim();
  const fieldErrors: Record<string, string> = {};
  if (wants !== "yes" && wants !== "no") fieldErrors.wants_renewal = "اختر نعم أو لا.";
  if (reason.length < 2) fieldErrors.reason = "وضّح السبب باختصار.";
  if (experience.length < 2) fieldErrors.experience = "اكتب باختصار كيف كانت تجربتك.";
  if (Object.keys(fieldErrors).length) return { error: "راجع الحقول المحددة.", fieldErrors };
  if (!(await allow(`exit:u:${user.id}`, 5, 3600))) return { error: LIMITED };
  let who: string;
  try {
    who = await withUser(user.id, async (tx) => {
      await tx.query("SELECT app.submit_exit_survey($1,$2,$3,$4)", [orderNo, wants === "yes", reason, experience]);
      return (await tx.query("SELECT contact_name FROM orders WHERE order_no = $1", [orderNo])).rows[0]?.contact_name ?? "";
    });
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, `استبيان نهاية البرنامج — ${who}`,
    `رد ${who} على استبيان نهاية البرنامج (${orderNo}):\n\nرغبة بالتجديد: ${wants === "yes" ? "نعم" : "لا"}\nالسبب: ${reason}\n\nتجربته: ${experience}\n\nNav Coaching`);
  revalidatePath("/account");
  revalidatePath(`/account/orders/${orderNo}`);
  return { ok: true, message: "شكراً لك، وصلني ردك 🤍" };
}

// ---------- موعد بداية البرنامج (قبل التفعيل) ----------
export async function setStartPrefAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const orderNo = String(fd.get("order_no") ?? "");
  const mode = String(fd.get("start_mode") ?? "asap");
  const date = String(fd.get("start_date") ?? "");
  if (mode === "date" && !validStartPref(date)) return { error: "اختر تاريخاً من بكرة إلى شهر من اليوم.", fieldErrors: { start_date: "اختر تاريخاً من بكرة إلى شهر من اليوم." } };
  try {
    await withUser(user.id, (tx) => tx.query("SELECT app.set_my_start_pref($1, $2::date)", [orderNo, mode === "date" ? date : null]));
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  revalidatePath(`/account/orders/${orderNo}`);
  return { ok: true, message: mode === "date" ? "تم حفظ موعد البداية." : "تم: نبدأ بأقرب وقت." };
}

// ---------- استبيان العضو بدون طلب (من «بياناتي») ----------
export async function saveProfileAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const parsed = profileSchema.safeParse(formToObject(fd));
  if (!parsed.success) {
    const fieldErrors: Record<string, string> = {};
    for (const issue of parsed.error.issues) fieldErrors[String(issue.path[0])] ??= issue.message;
    return { error: "راجع الحقول المحددة.", fieldErrors };
  }
  if (!(await allow(`profile:u:${user.id}`, 20, 3600))) return { error: LIMITED };
  const { answers, health, flag } = splitProfile(parsed.data);
  try {
    await withUser(user.id, (tx) => tx.query("SELECT app.save_my_profile($1, $2, $3)", [JSON.stringify(answers), JSON.stringify(health), flag]));
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  revalidatePath("/account");
  revalidatePath("/account/profile");
  return { ok: true, message: "تم حفظ استبيانك. شكراً لك." };
}
