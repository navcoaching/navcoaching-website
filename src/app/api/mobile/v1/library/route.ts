import { getCurrentUser } from "@/lib/session";
import { getMyBooklets, getMyFreePlans } from "@/lib/data";

export const dynamic = "force-dynamic";

// ملفاتي في التطبيق: الجداول المجانية التي طلبها المستخدم، والكتيبات (للمشتركين)
export async function GET() {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const [plans, booklets] = await Promise.all([getMyFreePlans(user.id), getMyBooklets(user.id)]);
  return Response.json({
    free_plans: plans.map((p) => ({ id: p.request_id, slug: p.slug, title: p.title, summary: p.summary, has_file: p.has_file, url: `/api/free-plans/${p.request_id}` })),
    booklets: booklets.map((b) => ({ id: b.id, title: b.title, description: b.description, url: `/api/booklets/${b.id}` })),
  }, { headers: { "Cache-Control": "private, no-store" } });
}
