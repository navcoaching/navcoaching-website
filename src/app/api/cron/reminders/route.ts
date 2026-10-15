import { timingSafeEqual } from "node:crypto";
import { runReminders } from "@/lib/reminders";

export const dynamic = "force-dynamic";

// يستدعيه netlify/functions/reminders.mts كل ساعة، ومحمي بـ CRON_SECRET.
export async function POST(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (!secret) return Response.json({ error: "CRON_SECRET غير مضبوط" }, { status: 503 });
  const given = Buffer.from(req.headers.get("x-cron-secret") ?? "");
  const want = Buffer.from(secret);
  if (given.length !== want.length || !timingSafeEqual(given, want)) return new Response("Unauthorized", { status: 401 });
  // للتشغيل اليدوي أو الاختبار فقط (بعد التحقق من السر): {"ignore_quiet_hours": true}
  const body = await req.json().catch(() => ({}));
  const result = await runReminders(new Date(), { ignoreQuietHours: body?.ignore_quiet_hours === true });
  return Response.json(result);
}
