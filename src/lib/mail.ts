import "server-only";
import { Resend } from "resend";
import { pool } from "./db";
import { renderEmail, type EmailInput } from "./email-template";
import { pushToCoaches } from "./push";

/**
 * الإرسال عبر Resend فقط عند توفر RESEND_API_KEY و MAIL_FROM.
 * في التطوير فقط (وليس الإنتاج) تُحفظ الرسائل في جدول dev_mailbox لتجربة الدخول والاختبارات.
 * في الإنتاج بدون مفتاح: يرمي خطأ صريحاً بدل التظاهر بأن البريد أُرسل.
 */
export function mailConfigured() {
  return Boolean(process.env.RESEND_API_KEY && process.env.MAIL_FROM);
}

export function devMailboxEnabled() {
  // E2E_MAILBOX يسمح بتشغيل الاختبارات على نسخة البناء محلياً فقط، ويُتجاهل تماماً على Netlify.
  if (process.env.NETLIFY === "true") return false;
  return process.env.NODE_ENV !== "production" || process.env.E2E_MAILBOX === "1";
}

/** يرجع "sent" عند الإرسال الفعلي عبر Resend، و"dev" عند الحفظ في صندوق التطوير فقط. */
export async function sendMail(to: string, subject: string, text: string, html?: string): Promise<"sent" | "dev"> {
  if (mailConfigured()) {
    const resend = new Resend(process.env.RESEND_API_KEY);
    const { error } = await resend.emails.send({ from: process.env.MAIL_FROM!, to, subject, text, ...(html ? { html } : {}) });
    if (error) throw new Error(`mail failed: ${error.message}`);
    return "sent";
  }
  if (devMailboxEnabled()) {
    await pool.query("INSERT INTO dev_mailbox (recipient, subject, body) VALUES ($1, $2, $3)", [to, subject, text]);
    if (html && process.env.MAIL_PREVIEW_DIR) await savePreview(subject, html);
    console.info(`[dev-mail] to=${to} subject=${subject}`);
    return "dev";
  }
  throw new Error("البريد غير مفعّل: أضيفي RESEND_API_KEY و MAIL_FROM");
}

/**
 * تنبيهات الطلبات: رقم الطلب والحالة فقط، بدون أي بيانات صحية أو إجابات الاستبيان.
 * لا تُفشل العملية الأساسية إذا تعذر الإرسال.
 */
export async function notifySafe(to: string | undefined | null, subject: string, text: string, html?: Partial<EmailInput>) {
  if (!to) return;
  try {
    await sendMail(to, subject, text, await coachHtml(subject, text, html));
  } catch (err) {
    console.error("[notify] skipped:", (err as Error).message);
  }
  // نفس التنبيه على جوال المدربة (العنوان فقط)
  if (to === process.env.COACH_NOTIFY_EMAIL) await pushToCoaches(subject);
}

/** في التطوير فقط: حفظ نسخة HTML للمعاينة (MAIL_PREVIEW_DIR) */
async function savePreview(subject: string, html: string) {
  const { writeFile, mkdir } = await import("node:fs/promises");
  const dir = process.env.MAIL_PREVIEW_DIR!;
  await mkdir(dir, { recursive: true });
  await writeFile(`${dir}/${Date.now()}-${subject.replace(/[^\p{L}\p{N}-]+/gu, "_").slice(0, 60)}.html`, html);
}

/** هوية البريد: رابط الموقع والتواصل والاسم التجاري (من الإعدادات العامة) */
export async function mailBrand(q: { query: (sql: string) => Promise<{ rows: { key: string; value: Record<string, string> }[] }> }) {
  const { rows } = await q.query("SELECT key, value FROM site_settings WHERE key IN ('contact', 'legal') AND is_public");
  const v = Object.fromEntries(rows.map((r) => [r.key, r.value]));
  return {
    site: (process.env.NEXT_PUBLIC_SITE_URL || "https://navcoaching.com").replace(/\/$/, ""),
    whatsapp: v.contact?.whatsapp, instagram: v.contact?.instagram, legalName: v.legal?.name, cr: v.legal?.cr,
  };
}

/** تنبيه المدربة بنفس تصميم بريد المتدرب، مع زر لصفحة الطلب في لوحة الإدارة إن وُجد رقم طلب */
async function coachHtml(subject: string, text: string, extra?: Partial<EmailInput>) {
  try {
    const brand = await mailBrand(pool);
    const no = `${subject}\n${text}`.match(/NAV-\d{6}-[A-Z0-9]{5}/)?.[0];
    const body = text.replace(/\n*Nav Coaching\s*$/, "").replace(/\n*التفاصيل في لوحة الإدارة\.?\s*$/, "");
    return renderEmail({
      kicker: "تنبيه للمدربة", name: "الكوتش ساره", brand, message: body,
      headline: subject.replace(/\s*[—-]?\s*NAV-\d{6}-[A-Z0-9]{5}/, "").trim() || subject,
      cta: { label: no ? "فتح الطلب في لوحة الإدارة" : "فتح لوحة الإدارة", url: `${brand.site}/admin${no ? `/orders/${no}` : ""}` },
      ...extra,
    });
  } catch {
    return undefined; // يُرسل النص العادي فقط
  }
}
