import "server-only";
import { dbErrorMessage, withAnon, withUser } from "./db";
import { allow } from "./rate";
import { normalizedPhone } from "./intake";
import { cleanUpload, newKey, UploadError } from "./uploads";
import { storage } from "./storage";
import { notifySafe } from "./mail";
import { riyals } from "./format";

export type AddonKind = "program_review" | "form_check" | "meal_library";
export const ADDON_KINDS: AddonKind[] = ["program_review", "form_check", "meal_library"];

/** الخدمات الإضافية المنشورة (منتجات لها app_addon) مع أسعارها */
export async function listAddons() {
  return withAnon(async (tx) => (await tx.query(
    `SELECT p.app_addon AS kind, p.name, p.audience, p.items, o.sku, o.label, o.price_halalas
       FROM products p JOIN product_offers o ON o.product_id = p.id AND o.active
      WHERE p.status = 'published' AND p.app_addon IS NOT NULL
      ORDER BY p.sort, o.price_halalas`)).rows as { kind: AddonKind; name: string; audience: string | null; items: unknown; sku: string; label: string; price_halalas: number }[]);
}

const GENERIC = "تعذّر إرسال الطلب. حاول مرة ثانية.";

/**
 * طلب خدمة إضافية من التطبيق: ينشئ الطلب بنفس دالة الطلبات (ينتظر التحويل)، ثم يرفق محتواه:
 * البرنامج وسجله (راجعي جدولي) أو مقطع الفيديو (تصحيح الأداء). الفشل في الإرفاق يلغي الطلب نفسه.
 */
export async function createAddonOrder(user: { id: string; name: string; email: string }, fd: FormData): Promise<{ ok: true; orderNo: string } | { error: string }> {
  const sku = String(fd.get("sku") ?? "");
  const idem = String(fd.get("idempotency_key") ?? "");
  const rawPhone = String(fd.get("phone") ?? "").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)));
  const phone = normalizedPhone(String(fd.get("cc") ?? "+966"), rawPhone);
  const note = String(fd.get("note") ?? "").trim().slice(0, 1000);
  if (!/^[a-z0-9-]{1,60}$/.test(sku) || idem.length < 16 || idem.length > 100) return { error: GENERIC };
  if (!/^\+\d{9,15}$/.test(phone)) return { error: "اكتب رقم جوال صحيح (واتساب) للتواصل." };
  if (!(await allow(`addon:u:${user.id}`, 6, 3600))) return { error: "طلبات كثيرة. حاول بعد قليل." };

  const offer = await withAnon(async (tx) => (await tx.query(
    `SELECT p.app_addon AS kind FROM product_offers o JOIN products p ON p.id = o.product_id
      WHERE o.sku = $1 AND o.active AND p.status = 'published' AND p.app_addon IS NOT NULL`, [sku])).rows[0] as { kind: AddonKind } | undefined);
  if (!offer) return { error: "هذه الخدمة غير متاحة حالياً." };

  // محتوى الطلب: البرنامج وسجله (راجعي جدولي)، أو اسم التمرين (تصحيح الأداء)
  let payload: unknown = null;
  const rawPayload = String(fd.get("payload") ?? "");
  if (rawPayload) {
    try { payload = JSON.parse(rawPayload); } catch { return { error: "تعذّرت قراءة الطلب. حاول مرة ثانية." }; }
    if (!payload || typeof payload !== "object" || Array.isArray(payload) || rawPayload.length > 150_000) return { error: "محتوى الطلب كبير جداً أو غير صالح." };
  }
  if (offer.kind === "program_review" && !payload) return { error: "اختر البرنامج اللي تبي المدربة تراجعه." };
  let video: Awaited<ReturnType<typeof cleanUpload>> | null = null;
  if (offer.kind === "form_check") {
    try { video = await cleanUpload(fd.get("video") as File | null, "video"); }
    catch (err) { return { error: err instanceof UploadError ? err.message : GENERIC }; }
  }

  const store = await storage();
  const key = video ? newKey("addons", video.ext) : null;
  if (video && key) await store.put(key, video.data, video.mime);
  let orderNo: string;
  try {
    orderNo = await withUser(user.id, async (tx) => {
      const { rows: [r] } = await tx.query("SELECT app.create_order($1,$2,false,$3,$4,'{}'::jsonb,'{}'::jsonb,false,$5,$6) AS no",
        [sku, idem, user.name || user.email.split("@")[0], phone, "لا، أفضّل الخصوصية", note]);
      const exists = (await tx.query("SELECT 1 FROM addon_requests a JOIN orders o ON o.id = a.order_id WHERE o.order_no = $1", [r.no])).rowCount;
      if (!exists) await tx.query("SELECT app.submit_addon($1,$2,$3,$4,$5,$6)", [r.no, payload == null ? null : JSON.stringify(payload), note, key, video?.mime ?? null, video?.size ?? null]);
      return r.no as string;
    });
  } catch (err) {
    if (key) await store.remove(key).catch(() => {});
    return { error: dbErrorMessage(err) ?? GENERIC };
  }
  const o = await withUser(user.id, async (tx) => (await tx.query("SELECT product_name, amount_due_halalas FROM orders WHERE order_no = $1", [orderNo])).rows[0]);
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, `طلب خدمة من التطبيق ${orderNo}`,
    `طلب جديد من تطبيق الجوال\nرقم الطلب: ${orderNo}\nالخدمة: ${o.product_name}\nالمبلغ: ${riyals(o.amount_due_halalas)}\n\nالتفاصيل في لوحة الإدارة بعد وصول التحويل.`);
  return { ok: true, orderNo };
}
