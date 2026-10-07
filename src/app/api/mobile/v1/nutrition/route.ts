import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { loadCurrentOrder } from "@/lib/current-order";
import { loadNutritionDay } from "@/lib/nutrition-data";
import { kcalOf, mealName, sumMacros } from "@/lib/nutrition";
import { addDays, riyadhDate } from "@/lib/schedule";

export const dynamic = "force-dynamic";

// التغذية للمتدرب في التطبيق: نفس بيانات صفحة «التغذية والمكملات» في الموقع ليوم واحد (آخر 60 يوماً)
export async function GET(req: Request) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const cur = await loadCurrentOrder(user.id);
  if (!cur) return Response.json({ nutrition: null }, { headers: { "Cache-Control": "private, no-store" } });
  const today = riyadhDate();
  const q = new URL(req.url).searchParams.get("date") ?? "";
  const date = /^\d{4}-\d{2}-\d{2}$/.test(q) && q <= today && q >= addDays(today, -60) ? q : today;
  const d = await withUser(user.id, (tx) => loadNutritionDay(tx, user.id, cur.order_no, date, true));
  if (!d) return Response.json({ nutrition: null }, { headers: { "Cache-Control": "private, no-store" } });
  const own = d.plans.flatMap((p) => p.meals.map((m) => ({
    id: m.id, kind: m.kind, label: mealName(m.kind, m.title, m.items.map((it) => it.food).join("، ")), kcal: m.total.kcal, protein: m.total.protein, carbs: m.total.carbs, fat: m.total.fat, own: true,
  })));
  const seen = new Set(own.map((m) => m.id));
  const ready = [...own, ...d.library.filter((m) => !seen.has(m.id)).map((m) => ({
    id: m.id, kind: m.kind, label: mealName(m.kind, m.title, m.foods), kcal: kcalOf(m), protein: m.protein, carbs: m.carbs, fat: m.fat, own: false,
  }))];
  return Response.json({
    nutrition: {
      order_no: d.o.order_no, date, today,
      target: d.target ?? null,
      total: sumMacros(d.logs),
      logs: d.logs.map((l) => ({ ...l, kcal: kcalOf(l) })),
      plans: d.plans.map((p) => ({ id: p.id, name: p.name, notes: p.notes, total: p.total, meals: p.meals })),
      routine: d.routine,
      ready,
      details: d.details,
    },
  }, { headers: { "Cache-Control": "private, no-store" } });
}
