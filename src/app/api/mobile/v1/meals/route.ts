import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { kcalOf } from "@/lib/nutrition";

export const dynamic = "force-dynamic";

// «وجباتي»: وجبات قوالب التغذية التي تصممها المدربة، بمكوناتها وطريقة تحضيرها.
// قاعدة البيانات تقرر الوصول (app.has_meals: عنده برنامج، أو اشترى «وجباتي» من الموقع، أو مشترك «ناف برو»)؛ غيره يرجع access=false.
export async function GET() {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const body = await withUser(user.id, async (tx) => {
    const access = (await tx.query("SELECT app.is_coach() OR app.has_meals() AS a")).rows[0].a as boolean;
    if (!access) return { access: false, meals: [] };
    const meals = (await tx.query(`SELECT meal_id::text AS id, plan_name, kind, title, protein::float, carbs::float, fat::float FROM app.library_meals() ORDER BY title`)).rows;
    const details = meals.length
      ? (await tx.query(`SELECT meal_id::text AS id, method, items FROM app.meal_details($1::uuid[])`, [meals.map((m) => m.id)])).rows
      : [];
    const byId = new Map(details.map((d) => [d.id, d]));
    return { access: true, meals: meals.map((m) => ({ ...m, kcal: Math.round(kcalOf(m)), method: byId.get(m.id)?.method ?? null, items: byId.get(m.id)?.items ?? [] })) };
  });
  return Response.json(body, { headers: { "Cache-Control": "private, no-store" } });
}
