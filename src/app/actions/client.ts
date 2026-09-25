"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { dbErrorMessage, withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { intakeSchema, normalizedPhone, splitIntake } from "@/lib/intake";
import { allow, clientIp } from "@/lib/rate";
import { cleanUpload, newKey, UploadError } from "@/lib/uploads";
import { storage } from "@/lib/storage";
import { notifySafe } from "@/lib/mail";
import { riyals } from "@/lib/format";

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

// ---------- إنشاء الطلب مع التقييم ----------
export async function createOrderAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await getCurrentUser();
  if (!user) return { error: "انتهت الجلسة. سجّل الدخول مرة أخرى ثم أعد الإرسال (إجاباتك محفوظة على جهازك)." };

  const parsed = intakeSchema.safeParse(formToObject(fd));
  if (!parsed.success) {
    const fieldErrors: Record<string, string> = {};
    for (const issue of parsed.error.issues) fieldErrors[String(issue.path[0])] ??= issue.message;
    if (fieldErrors.website) return { error: GENERIC };
    return { error: "راجع الحقول المحددة.", fieldErrors };
  }
  const v = parsed.data;

  if (!(await allow(`order:u:${user.id}`, 6, 3600)) || !(await allow(`order:ip:${await clientIp()}`, 20, 3600))) return { error: LIMITED };

  const { answers, health, healthFlag } = splitIntake(v);
  let orderNo: string;
  try {
    orderNo = await withUser(user.id, async (tx) => {
      const { rows } = await tx.query(
        "SELECT app.create_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS no",
        [v.sku, v.idempotency_key, v.student === "نعم", v.name, normalizedPhone(v.cc, v.phone),
         JSON.stringify(answers), JSON.stringify(health), healthFlag, v.media, v.notes],
      );
      return rows[0].no as string;
    });
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }

  const summary = await withUser(user.id, async (tx) =>
    (await tx.query("SELECT product_name, offer_label, amount_due_halalas FROM orders WHERE order_no = $1", [orderNo])).rows[0]);
  await notifySafe(
    process.env.COACH_NOTIFY_EMAIL,
    `طلب جديد ${orderNo}`,
    `طلب جديد في Nav Coaching\nرقم الطلب: ${orderNo}\nالبرنامج: ${summary.product_name} — ${summary.offer_label}\nالمبلغ: ${summary.amount_due_halalas == null ? "بانتظار تأكيد خصم الطالب" : riyals(summary.amount_due_halalas)}\n\nالتفاصيل في لوحة الإدارة.`,
  );
  redirect(`/account/orders/${orderNo}?new=1`);
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

// ---------- التقييم ----------
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
