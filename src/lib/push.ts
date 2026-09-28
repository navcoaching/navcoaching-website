import "server-only";
import webpush from "web-push";
import { withUser, type Tx } from "./db";

// نفس المعرّف في src/lib/reminders.ts (مستخدم النظام: app.is_coach() صحيحة له)
const SYSTEM_USER = "system-scheduler";

/**
 * إشعارات الجوال (Web Push). تعمل فقط عند ضبط مفاتيح VAPID في متغيرات البيئة:
 *   NEXT_PUBLIC_VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:… أو https://…)
 * في الاختبارات المحلية فقط: PUSH_MOCK=1 يسجّل الإرسال بدون الاتصال بخوادم Apple/Google.
 */
export function pushMock() {
  return process.env.NETLIFY !== "true" && process.env.PUSH_MOCK === "1";
}
// القيم تُقصّ من المسافات والأسطر الزائدة (شائعة عند النسخ واللصق في Netlify)
const env = (k: "NEXT_PUBLIC_VAPID_PUBLIC_KEY" | "VAPID_PRIVATE_KEY" | "VAPID_SUBJECT") => (process.env[k] ?? "").trim();
export function pushConfigured() {
  return Boolean(env("NEXT_PUBLIC_VAPID_PUBLIC_KEY") && env("VAPID_PRIVATE_KEY") && env("VAPID_SUBJECT")) || pushMock();
}
export const pushPublicKey = () => env("NEXT_PUBLIC_VAPID_PUBLIC_KEY") || (pushMock() ? "mock" : "");

let configured = false;
function setup() {
  if (configured || pushMock()) return;
  const subject = env("VAPID_SUBJECT");
  webpush.setVapidDetails(/^(mailto:|https:\/\/)/.test(subject) ? subject : `mailto:${subject}`, env("NEXT_PUBLIC_VAPID_PUBLIC_KEY"), env("VAPID_PRIVATE_KEY"));
  configured = true;
}

export type PushPayload = { title: string; body: string; url: string; tag?: string };
export type PushResult = { sent: number; failed: number; removed: number; errors: string[] };

/** يرسل لكل أجهزة المستخدم، ويحذف الاشتراكات المنتهية (404/410). لا يرمي أخطاء. */
export async function sendPush(tx: Tx, userId: string, payload: PushPayload): Promise<PushResult> {
  const subs = (await tx.query(`SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = $1`, [userId])).rows as
    { id: number; endpoint: string; p256dh: string; auth: string }[];
  const out: PushResult = { sent: 0, failed: 0, removed: 0, errors: [] };
  if (!subs.length) return out;
  if (pushMock()) { out.sent = subs.length; return out; }
  try { setup(); } catch (err) {
    out.failed = subs.length; out.errors.push(`إعداد المفاتيح: ${(err as Error).message.slice(0, 120)}`);
    console.error("[push] setup", (err as Error).message); return out;
  }
  const body = JSON.stringify({ ...payload, body: payload.body.slice(0, 300) });
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body, { TTL: 60 * 60 * 24, timeout: 10_000 });
      out.sent++;
      await tx.query(`UPDATE push_subscriptions SET last_used_at = now() WHERE id = $1`, [s.id]);
    } catch (err) {
      const code = (err as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { await tx.query(`DELETE FROM push_subscriptions WHERE id = $1`, [s.id]); out.removed++; }
      else {
        out.failed++;
        const body = String((err as { body?: string }).body ?? "").slice(0, 120);
        out.errors.push(`${code ?? "?"} ${body || (err as Error).message.slice(0, 120)}`.trim());
        console.error("[push]", code, (err as Error).message.slice(0, 200), body);
      }
    }
  }
  return out;
}

/**
 * تنبيهات المدربة على جوالها (بجانب الإيميل): العنوان فقط بدون أي تفاصيل أو بيانات صحية.
 * تُرسل لكل أجهزة حسابات المدربة التي فعّلت الإشعارات. لا ترمي أخطاء.
 */
export async function pushToCoaches(title: string, url = "/admin") {
  if (!pushConfigured()) return;
  try {
    await withUser(SYSTEM_USER, async (tx) => {
      const { rows } = await tx.query(`SELECT DISTINCT s.user_id FROM push_subscriptions s JOIN "user" u ON u.id = s.user_id WHERE u.role = 'coach'`);
      for (const r of rows) await sendPush(tx, r.user_id, { title: "Nav Coaching — تنبيه", body: title.slice(0, 120), url, tag: "coach" });
    });
  } catch (err) {
    console.error("[push] coach", (err as Error).message);
  }
}

/** مفتاحا VAPID جديدان (للمدربة لتضعهما في Netlify). لا يُحفظان في الموقع. */
export function generateVapidKeys() {
  return webpush.generateVAPIDKeys();
}
