import { dbErrorMessage, withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { storage } from "@/lib/storage";
import { notifySafe } from "@/lib/mail";
import { allow } from "@/lib/rate";

export const dynamic = "force-dynamic";

// حذف الحساب من التطبيق (شرط Apple). يتطلب تأكيداً صريحاً من الواجهة، ويُبلَّغ المدربة بأرقام الطلبات المحذوفة.
export async function POST(req: Request) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "سجّل الدخول أولاً." }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as { confirm?: string };
  if (body.confirm !== "حذف") return Response.json({ error: "اكتب «حذف» للتأكيد." }, { status: 422 });
  if (!(await allow(`self-delete:u:${user.id}`, 3, 3600))) return Response.json({ error: "محاولات كثيرة. حاول لاحقاً." }, { status: 429 });
  let res: { email: string; orders: string[]; keys: string[] };
  try {
    res = await withUser(user.id, async (tx) => (await tx.query("SELECT app.delete_my_account() AS r")).rows[0].r);
  } catch (err) {
    return Response.json({ error: dbErrorMessage(err) ?? "تعذّر حذف الحساب. تواصل معنا على واتساب." }, { status: 422 });
  }
  const store = await storage();
  await Promise.all(res.keys.map((k) => store.remove(k).catch(() => {})));
  await notifySafe(process.env.COACH_NOTIFY_EMAIL, `حذف حساب من التطبيق: ${res.email}`,
    `حذف العضو حسابه بنفسه من تطبيق الجوال.\nالبريد: ${res.email}\nالطلبات المحذوفة: ${res.orders.length ? res.orders.join("، ") : "لا يوجد"}`);
  return Response.json({ ok: true });
}
