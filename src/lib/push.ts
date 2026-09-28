import "server-only";
import webpush from "web-push";
import type { Tx } from "./db";

/**
 * إشعارات الجوال (Web Push). تعمل فقط عند ضبط مفاتيح VAPID في متغيرات البيئة:
 *   NEXT_PUBLIC_VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:… أو https://…)
 * في الاختبارات المحلية فقط: PUSH_MOCK=1 يسجّل الإرسال بدون الاتصال بخوادم Apple/Google.
 */
export function pushMock() {
  return process.env.NETLIFY !== "true" && process.env.PUSH_MOCK === "1";
}
export function pushConfigured() {
  return Boolean(process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY && process.env.VAPID_PRIVATE_KEY && process.env.VAPID_SUBJECT) || pushMock();
}
export const pushPublicKey = () => process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ?? (pushMock() ? "mock" : "");

let configured = false;
function setup() {
  if (configured || pushMock()) return;
  webpush.setVapidDetails(process.env.VAPID_SUBJECT!, process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY!, process.env.VAPID_PRIVATE_KEY!);
  configured = true;
}

export type PushPayload = { title: string; body: string; url: string; tag?: string };
export type PushResult = { sent: number; failed: number; removed: number };

/** يرسل لكل أجهزة المستخدم، ويحذف الاشتراكات المنتهية (404/410). لا يرمي أخطاء. */
export async function sendPush(tx: Tx, userId: string, payload: PushPayload): Promise<PushResult> {
  const subs = (await tx.query(`SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = $1`, [userId])).rows as
    { id: number; endpoint: string; p256dh: string; auth: string }[];
  const out: PushResult = { sent: 0, failed: 0, removed: 0 };
  if (!subs.length) return out;
  if (pushMock()) { out.sent = subs.length; return out; }
  setup();
  const body = JSON.stringify({ ...payload, body: payload.body.slice(0, 300) });
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body, { TTL: 60 * 60 * 24, timeout: 10_000 });
      out.sent++;
      await tx.query(`UPDATE push_subscriptions SET last_used_at = now() WHERE id = $1`, [s.id]);
    } catch (err) {
      const code = (err as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { await tx.query(`DELETE FROM push_subscriptions WHERE id = $1`, [s.id]); out.removed++; }
      else { out.failed++; console.error("[push]", code, (err as Error).message.slice(0, 200)); }
    }
  }
  return out;
}

/** مفتاحا VAPID جديدان (للمدربة لتضعهما في Netlify). لا يُحفظان في الموقع. */
export function generateVapidKeys() {
  return webpush.generateVAPIDKeys();
}
