import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";

export const dynamic = "force-dynamic";

// بدائل تمرين في برنامج المدربة (نفس قائمة صفحة التمرين في الموقع؛ قاعدة البيانات تتحقق من الملكية)
export async function GET(req: Request) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const item = new URL(req.url).searchParams.get("item") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(item)) return Response.json({ options: [] });
  const options = await withUser(user.id, async (tx) =>
    (await tx.query(`SELECT id, name, is_coach_choice, is_current FROM app.swap_options($1)`, [item])).rows).catch(() => []);
  return Response.json({ options }, { headers: { "Cache-Control": "private, no-store" } });
}
