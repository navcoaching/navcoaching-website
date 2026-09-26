import "server-only";
import { Resend } from "resend";
import { pool } from "./db";

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
export async function sendMail(to: string, subject: string, text: string): Promise<"sent" | "dev"> {
  if (mailConfigured()) {
    const resend = new Resend(process.env.RESEND_API_KEY);
    const { error } = await resend.emails.send({ from: process.env.MAIL_FROM!, to, subject, text });
    if (error) throw new Error(`mail failed: ${error.message}`);
    return "sent";
  }
  if (devMailboxEnabled()) {
    await pool.query("INSERT INTO dev_mailbox (recipient, subject, body) VALUES ($1, $2, $3)", [to, subject, text]);
    console.info(`[dev-mail] to=${to} subject=${subject}`);
    return "dev";
  }
  throw new Error("البريد غير مفعّل: أضيفي RESEND_API_KEY و MAIL_FROM");
}

/**
 * تنبيهات الطلبات: رقم الطلب والحالة فقط، بدون أي بيانات صحية أو إجابات الاستبيان.
 * لا تُفشل العملية الأساسية إذا تعذر الإرسال.
 */
export async function notifySafe(to: string | undefined | null, subject: string, text: string) {
  if (!to) return;
  try {
    await sendMail(to, subject, text);
  } catch (err) {
    console.error("[notify] skipped:", (err as Error).message);
  }
}
