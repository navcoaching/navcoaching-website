import "server-only";
import type { Tx } from "./db";
import { sendMail, mailConfigured, devMailboxEnabled, mailBrand } from "./mail";
import { renderEmail, statusCopy } from "./email-template";
import { pushConfigured, sendPush } from "./push";

/**
 * إشعارات المتدرب عبر البريد وواتساب وإشعارات الجوال (push)، مع سجل لكل محاولة (notification_log).
 * - النص مختصر دائماً، بدون بيانات صحية، ومعه رابط آمن لصفحة الطلب داخل الحساب.
 * - تُحترم تفضيلات المتدرب (user_prefs) وموافقته على التواصل بواتساب في الاستبيان.
 * - واتساب يعمل فقط بعد ضبط WhatsApp Cloud API (انظري docs/FOLLOWUP.md)؛ قبل ذلك يُسجَّل «تم التخطي» مع السبب.
 * - occasion يمنع تكرار نفس التذكير (مثلاً: قرب الانتهاء بـ 7 أيام) لنفس الطلب والقناة.
 */

export type Channel = "email" | "whatsapp" | "push";
export type ChannelResult = { channel: Channel; status: "sent" | "simulated" | "failed" | "skipped" | "duplicate"; detail?: string };

export function whatsappConfigured() {
  return Boolean(process.env.WHATSAPP_TOKEN && process.env.WHATSAPP_PHONE_NUMBER_ID && process.env.WHATSAPP_TEMPLATE_NAME);
}

/**
 * رسالة قالب عبر WhatsApp Cloud API (Meta). الرسائل التي تبدأها المنشأة تتطلب قالباً معتمداً من Meta.
 * القالب المطلوب: متغيران في النص — {{1}} نص الإشعار، {{2}} رابط الحساب.
 */
async function sendWhatsApp(toE164: string, text: string, link: string) {
  const to = toE164.replace(/[^\d]/g, "");
  const url = `https://graph.facebook.com/${process.env.WHATSAPP_API_VERSION ?? "v21.0"}/${process.env.WHATSAPP_PHONE_NUMBER_ID}/messages`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.WHATSAPP_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: process.env.WHATSAPP_TEMPLATE_NAME,
        language: { code: process.env.WHATSAPP_TEMPLATE_LANG ?? "ar" },
        components: [{ type: "body", parameters: [
          // واتساب لا يقبل أسطراً جديدة داخل متغيرات القالب
          { type: "text", text: text.replace(/\s*\n+\s*/g, " — ").slice(0, 900) },
          { type: "text", text: link },
        ] }],
      },
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`WhatsApp ${res.status}: ${body.slice(0, 200)}`);
  }
}

export type NotifyTarget = { orderId: string; orderNo: string; userId: string };

export async function notifyTrainee(
  tx: Tx,
  target: NotifyTarget,
  opts: { kind: string; subject: string; text: string; occasion?: string | null; channels?: Channel[] },
): Promise<ChannelResult[]> {
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  const link = `${site}/account/orders/${target.orderNo}`;
  const { rows: [info] } = await tx.query(
    `SELECT u.email, coalesce(o.contact_phone, u.phone) AS phone, o.contact_name, o.status, o.category, o.product_name, o.offer_label,
            o.amount_due_halalas, o.payment_method, o.created_at,
            coalesce(p.email_enabled, true) AS email_on, coalesce(p.whatsapp_enabled, true) AS wa_on, coalesce(p.push_enabled, true) AS push_on,
            (i.consent_whatsapp_at IS NOT NULL) AS wa_consent
       FROM orders o JOIN "user" u ON u.id = o.user_id
       LEFT JOIN user_prefs p ON p.user_id = u.id
       LEFT JOIN intakes i ON i.order_id = o.id
      WHERE o.id = $1`, [target.orderId]);
  if (!info) return [];

  // نسخة HTML بهوية الموقع (النص العادي يبقى نفسه)؛ بريد الحالة يعرض خطوات الطلب وملخصه
  const html = async () => {
    const brand = await mailBrand(tx);
    const first = String(info.contact_name ?? "").trim().split(/\s+/)[0];
    const order = { orderNo: target.orderNo, createdAt: info.created_at, status: info.status, category: info.category, product: info.product_name,
      offer: info.offer_label, amountHalalas: info.amount_due_halalas, paymentMethod: info.payment_method };
    if (opts.kind === "status") {
      const c = statusCopy(info.status, info.category);
      return renderEmail({ name: first, headline: c.headline, message: c.message || opts.text, order, brand });
    }
    return renderEmail({ name: first, headline: opts.subject, message: opts.text, brand, cta: { label: "افتح حسابك", url: link } });
  };

  const results: ChannelResult[] = [];
  // إشعار الجوال فقط لمن فعّله على جهاز (بدون سجل «تم التخطي» لكل من لم يثبّت التطبيق)
  const hasDevice = pushConfigured() && Number((await tx.query("SELECT count(*) FROM push_subscriptions WHERE user_id = $1", [target.userId])).rows[0].count) > 0;
  const channels = opts.channels ?? (["email", "whatsapp", ...(hasDevice ? ["push"] : [])] as Channel[]);
  for (const channel of channels) {
    const body = channel === "email" ? `${opts.text}\n\nالتفاصيل في حسابك:\n${link}\n\nNav Coaching` : opts.text;
    const { rows: [claim] } = await tx.query("SELECT app.notify_claim($1,$2,$3,$4,$5,$6) AS id",
      [target.orderId, target.userId, opts.kind, channel, opts.occasion ?? null, body]);
    if (!claim.id) { results.push({ channel, status: "duplicate", detail: "أُرسل لهذه المناسبة سابقاً" }); continue; }

    let r: ChannelResult;
    try {
      if (channel === "email") {
        if (!info.email_on) r = { channel, status: "skipped", detail: "المتدرب أوقف إشعارات البريد" };
        else if (!mailConfigured() && !devMailboxEnabled()) r = { channel, status: "skipped", detail: "البريد غير مفعّل (RESEND_API_KEY / MAIL_FROM)" };
        else {
          const mode = await sendMail(info.email, opts.subject, body, await html());
          r = mode === "sent" ? { channel, status: "sent" } : { channel, status: "simulated", detail: "بيئة تطوير: حُفظ في صندوق التطوير ولم يُرسل فعلياً" };
        }
      } else if (channel === "push") {
        if (!info.push_on) r = { channel, status: "skipped", detail: "المتدرب أوقف إشعارات الجوال" };
        else if (!pushConfigured()) r = { channel, status: "skipped", detail: "إشعارات الجوال غير مفعّلة (مفاتيح VAPID)" };
        else {
          const p = await sendPush(tx, target.userId, { title: opts.subject, body: opts.text, url: `/account/orders/${target.orderNo}`, tag: opts.kind });
          r = p.sent > 0 ? { channel, status: "sent", detail: `${p.sent} جهاز` }
            : { channel, status: p.failed ? "failed" : "skipped", detail: p.failed ? "تعذّر الإرسال للجهاز" : "لا يوجد جهاز مفعّل" };
        }
      } else {
        if (!info.wa_on) r = { channel, status: "skipped", detail: "المتدرب أوقف إشعارات واتساب" };
        else if (!info.wa_consent) r = { channel, status: "skipped", detail: "لا توجد موافقة على التواصل بواتساب" };
        else if (!info.phone) r = { channel, status: "skipped", detail: "لا يوجد رقم جوال" };
        else if (!whatsappConfigured()) r = { channel, status: "skipped", detail: "واتساب غير مفعّل بعد (يحتاج WhatsApp Business API)" };
        else { await sendWhatsApp(info.phone, opts.text, link); r = { channel, status: "sent" }; }
      }
    } catch (err) {
      r = { channel, status: "failed", detail: (err as Error).message.slice(0, 300) };
    }
    await tx.query("SELECT app.notify_finish($1,$2,$3)", [claim.id, r.status, r.detail ?? null]);
    results.push(r);
  }
  return results;
}

export const RESULT_LABEL: Record<ChannelResult["status"], string> = {
  sent: "تم الإرسال", simulated: "محاكاة (بيئة تطوير)", failed: "فشل", skipped: "لم يُرسل", duplicate: "مكرر — لم يُرسل",
};
export const CHANNEL_LABEL: Record<Channel, string> = { email: "البريد", whatsapp: "واتساب", push: "إشعار الجوال" };
