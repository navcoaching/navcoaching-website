"use server";
import { z } from "zod";
import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { allow } from "@/lib/rate";
import { pushConfigured, sendPush } from "@/lib/push";

const subSchema = z.object({
  endpoint: z.string().url().startsWith("https://").max(1000),
  keys: z.object({ p256dh: z.string().min(20).max(200), auth: z.string().min(8).max(100) }),
});

/** حفظ اشتراك هذا الجهاز في إشعارات الجوال */
export async function savePushSubscriptionAction(sub: unknown, device: string): Promise<{ ok: boolean; error?: string }> {
  const user = await getCurrentUser();
  if (!user) return { ok: false, error: "سجّل الدخول أولاً." };
  if (!pushConfigured()) return { ok: false, error: "إشعارات الجوال غير مفعّلة حالياً." };
  const parsed = subSchema.safeParse(sub);
  if (!parsed.success) return { ok: false, error: "تعذّر تفعيل الإشعارات على هذا الجهاز." };
  const { endpoint, keys } = parsed.data;
  await withUser(user.id, async (tx) => {
    await tx.query("SELECT app.save_push_subscription($1,$2,$3,$4)", [endpoint, keys.p256dh, keys.auth, String(device ?? "").slice(0, 200)]);
    await tx.query(`INSERT INTO user_prefs (user_id, push_enabled) VALUES ($1, true) ON CONFLICT (user_id) DO UPDATE SET push_enabled = true, updated_at = now()`, [user.id]);
  });
  return { ok: true };
}

/** إلغاء الإشعارات على هذا الجهاز */
export async function deletePushSubscriptionAction(endpoint: string): Promise<{ ok: boolean }> {
  const user = await getCurrentUser();
  if (!user || typeof endpoint !== "string") return { ok: false };
  await withUser(user.id, (tx) => tx.query(`DELETE FROM push_subscriptions WHERE endpoint = $1 AND user_id = $2`, [endpoint, user.id]));
  return { ok: true };
}

/** إشعار تجربة لكل أجهزة المستخدم (حد: 5 بالساعة) */
export async function sendTestPushAction(): Promise<{ ok: boolean; error?: string; sent?: number }> {
  const user = await getCurrentUser();
  if (!user) return { ok: false, error: "سجّل الدخول أولاً." };
  if (!(await allow(`push-test:${user.id}`, 5, 3600))) return { ok: false, error: "جرّبت كثير. حاول بعد شوي." };
  const r = await withUser(user.id, (tx) => sendPush(tx, user.id, {
    title: "Nav Coaching", body: "تمام! إشعارات الجوال شغّالة على هذا الجهاز ✅", url: "/account", tag: "test",
  }));
  return r.sent ? { ok: true, sent: r.sent } : { ok: false, error: "ما وصل الإشعار. جرّب تفعيله من جديد." };
}

/** للمدربة: مفتاحا VAPID جديدان تضعهما في Netlify. لا يُحفظان في الموقع ولا يُسجَّلان */
export async function generateVapidKeysAction(): Promise<{ ok: boolean; publicKey?: string; privateKey?: string; error?: string }> {
  const user = await getCurrentUser();
  if (!user || user.role !== "coach") return { ok: false, error: "للمدربة فقط." };
  const { generateVapidKeys } = await import("@/lib/push");
  const k = generateVapidKeys();
  return { ok: true, publicKey: k.publicKey, privateKey: k.privateKey };
}
