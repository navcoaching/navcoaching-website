import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";

export const dynamic = "force-dynamic";

// «ناف برو»: بدائل الكوتش لكل تمرين، بمعرّفات مكتبة التطبيق المضمّنة (mobile/scripts/build-exercises.mjs).
// قاعدة البيانات تقرر الاستحقاق (app.has_pro)؛ غير المشترك يرجع pro=false بدون بيانات.
const slug = (s: string) => s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

export async function GET() {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const map = await withUser(user.id, async (tx) => (await tx.query<{ a: Record<string, string[]> | null }>("SELECT app.coach_alts() AS a")).rows[0].a);
  const alts = map ? Object.fromEntries(Object.entries(map).map(([k, v]) => [slug(k), v.map(slug)])) : {};
  return Response.json({ pro: map !== null, alts }, { headers: { "Cache-Control": "private, no-store" } });
}
