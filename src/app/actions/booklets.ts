"use server";
import { revalidatePath } from "next/cache";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getFreshUser } from "@/lib/session";
import { cleanUpload, newKey, UploadError } from "@/lib/uploads";
import { storage } from "@/lib/storage";
import { notifySafe } from "@/lib/mail";
import { normalizedPhone } from "@/lib/intake";
import { allow } from "@/lib/rate";
import { riyals } from "@/lib/format";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const s = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const fail = (err: unknown): ActionState => {
  if (err instanceof UploadError) return { error: err.message };
  const m = (err as Error).message ?? "";
  if (m.startsWith("user:")) return { error: m.slice(5) };
  return { error: dbErrorMessage(err) ?? GENERIC };
};
const bad = (msg: string) => new Error(`user:${msg}`);

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await getFreshUser();
  if (!u || u.role !== "coach") throw bad("للمدربة فقط.");
  return withUser(u.id, (tx) => fn(tx, u.id));
}
const refresh = () => { revalidatePath("/admin/booklets"); revalidatePath("/account"); revalidatePath("/booklets"); };

/** سعر البيع بالريال من النموذج: فاضي = غير معروض للبيع */
function priceHalalas(fd: FormData): number | null {
  const raw = s(fd, "price").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)));
  if (!raw) return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0 || n > 100000) throw bad("السعر بالريال، رقم من 0 إلى 100000.");
  return Math.round(n * 100) || null;
}

/** المدربة: رفع كتيب PDF جديد */
export async function uploadBookletAction(_: ActionState, fd: FormData): Promise<ActionState> {
  let key = "";
  try {
    const title = s(fd, "title"), description = s(fd, "description") || null;
    if (title.length < 2 || title.length > 120) throw bad("اكتبي اسم الكتيب (حتى 120 حرفاً).");
    if (description && description.length > 300) throw bad("الوصف أطول من 300 حرف.");
    const price = priceHalalas(fd);
    await asCoach(async () => {});
    const clean = await cleanUpload(fd.get("file") as File | null, "pdf");
    key = newKey("booklets", "pdf");
    await (await storage()).put(key, clean.data, clean.mime);
    await asCoach(async (tx, uid) => {
      const { rows: [b] } = await tx.query(
        `INSERT INTO booklets (title, description, file_key, file_size, file_sha256, published, sort, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,(SELECT coalesce(max(sort),0)+1 FROM booklets),$7) RETURNING id`,
        [title, description, key, clean.size, clean.sha256, fd.get("published") === "on", uid]);
      if (price) await tx.query("SELECT app.coach_set_booklet_price($1,$2)", [b.id, price]);
      await tx.query("INSERT INTO admin_log (actor_id, action, target, details) VALUES ($1,'booklet.upload',$2,$3)", [uid, title, JSON.stringify({ size: clean.size })]);
    });
  } catch (err) {
    if (key) await (await storage()).remove(key).catch(() => {});
    return fail(err);
  }
  refresh();
  return { ok: true, message: "تم رفع الكتيب." };
}

/** المدربة: تعديل الاسم والوصف والظهور */
export async function saveBookletAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = s(fd, "id");
  if (!UUID.test(id)) return { error: GENERIC };
  try {
    const title = s(fd, "title"), description = s(fd, "description") || null;
    if (title.length < 2 || title.length > 120) throw bad("اكتبي اسم الكتيب (حتى 120 حرفاً).");
    if (description && description.length > 300) throw bad("الوصف أطول من 300 حرف.");
    const price = priceHalalas(fd);
    await asCoach(async (tx) => {
      const r = await tx.query(`UPDATE booklets SET title=$2, description=$3, published=$4, updated_at=now() WHERE id=$1`,
        [id, title, description, fd.get("published") === "on"]);
      if (!r.rowCount) throw bad("الكتيب غير موجود.");
      // منتج البيع يتبع الاسم والظهور والسعر
      await tx.query("SELECT app.coach_set_booklet_price($1,$2)", [id, price]);
    });
  } catch (err) { return fail(err); }
  refresh();
  return { ok: true, message: "تم الحفظ." };
}

/** المدربة: حذف كتيب (يُحذف الملف من التخزين) */
export async function deleteBookletAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = s(fd, "id");
  if (!UUID.test(id)) return { error: GENERIC };
  let key = "";
  try {
    await asCoach(async (tx, uid) => {
      const { rows: [b] } = await tx.query(`DELETE FROM booklets WHERE id = $1 RETURNING file_key, title`, [id]);
      if (!b) throw bad("الكتيب غير موجود.");
      key = b.file_key;
      await tx.query("INSERT INTO admin_log (actor_id, action, target) VALUES ($1,'booklet.delete',$2)", [uid, b.title]);
    });
  } catch (err) { return fail(err); }
  await (await storage()).remove(key).catch(() => {});
  refresh();
  return { ok: true, message: "تم الحذف." };
}

export type BuyBookletState = ActionState & { orderNo?: string; needLogin?: boolean };

/**
 * شراء كتيب: ينشئ طلباً عادياً بانتظار التحويل (نفس دالة الطلبات وبدون استبيان)، ثم يُكمل الدفع من صفحة الطلب.
 * قاعدة البيانات تتحقق أن الكتيب معروض للبيع وبسعره؛ هنا نمنع التكرار لمن يملكه أو عنده طلب ينتظر الدفع.
 */
export async function buyBookletAction(_: BuyBookletState, fd: FormData): Promise<BuyBookletState> {
  const user = await getFreshUser();
  if (!user) return { needLogin: true, error: "تسجيل الدخول مطلوب للشراء." };
  const id = s(fd, "id"), idem = s(fd, "idempotency_key");
  if (!UUID.test(id) || idem.length < 16 || idem.length > 100) return { error: GENERIC_BUY };
  const phone = normalizedPhone(s(fd, "cc") || "+966", s(fd, "phone").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))));
  if (!/^\+\d{9,15}$/.test(phone)) return { error: "رقم جوال صحيح (واتساب) مطلوب للتواصل." };
  if (!(await allow(`booklet:u:${user.id}`, 6, 3600))) return { error: "طلبات كثيرة. المحاولة بعد قليل." };
  let orderNo = "";
  try {
    orderNo = await withUser(user.id, async (tx) => {
      const { rows: [b] } = await tx.query("SELECT sku, owned, pending_order FROM app.booklets_for_sale() WHERE id = $1", [id]);
      if (!b) throw bad("هذا الكتيب غير متاح للبيع حالياً.");
      if (b.owned) throw bad("الكتيب متاح في حسابك.");
      if (b.pending_order) return b.pending_order as string;
      const { rows: [r] } = await tx.query("SELECT app.create_order($1,$2,false,$3,$4,'{}'::jsonb,'{}'::jsonb,false,$5,'') AS no",
        [b.sku, idem, user.name || user.email.split("@")[0], phone, "لا، أفضّل الخصوصية"]);
      return r.no as string;
    });
  } catch (err) { return fail(err); }
  const o = await withUser(user.id, async (tx) => (await tx.query("SELECT product_name, amount_due_halalas FROM orders WHERE order_no = $1", [orderNo])).rows[0]);
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, `طلب كتيب ${orderNo}`,
    `طلب شراء كتيب\nرقم الطلب: ${orderNo}\nالكتيب: ${o?.product_name ?? ""}\nالمبلغ: ${riyals(o?.amount_due_halalas ?? 0)}\n\nبعد تأكيد الدفع من لوحة الإدارة يفتح الكتيب للمشتري تلقائياً.`);
  revalidatePath("/booklets");
  return { ok: true, orderNo };
}
const GENERIC_BUY = "تعذّر إنشاء الطلب. المحاولة مرة ثانية.";
