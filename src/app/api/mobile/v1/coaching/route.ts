import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { loadCurrentOrder } from "@/lib/current-order";
import { loadBlockData, type BlockRow } from "@/lib/program-data";
import { currentWeek } from "@/lib/training";
import { riyadhDate } from "@/lib/schedule";

export const dynamic = "force-dynamic";

// برنامج المدربة للمتدرب في التطبيق: نفس بيانات صفحة «برنامج التمرين» في الموقع (RLS: يظهر بعد تأكيد الدفع فقط)
export async function GET() {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const cur = await loadCurrentOrder(user.id);
  if (!cur) return Response.json({ coaching: null }, { headers: { "Cache-Control": "private, no-store" } });

  const body = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, product_name, status FROM orders WHERE order_no = $1 AND user_id = $2`, [cur.order_no, user.id]);
    if (!o) return null;
    const { rows: [block] } = await tx.query(
      `SELECT id, order_id, user_id, name, start_date::text, weeks, instructions, steps_goal_week, status FROM blocks
        WHERE order_id = $1 ORDER BY (status = 'active') DESC, created_at DESC LIMIT 1`, [o.id]) as { rows: BlockRow[] };
    const order = { order_no: o.order_no, product_name: o.product_name, status: o.status };
    if (!block) return { order, block: null };
    const data = await loadBlockData(tx, block);
    return {
      order,
      block: {
        id: block.id, name: block.name, weeks: block.weeks, start_date: block.start_date, instructions: block.instructions,
        read_only: block.status !== "active",
        current_week: currentWeek(block.start_date, riyadhDate(), block.weeks),
      },
      days: data.days.map((d) => ({
        id: d.id, title: d.title,
        items: d.items.map((i) => {
          const e = data.exercises.get(i.exercise_id);
          return {
            id: i.id, note: i.note, plan: i.plan,
            exercise: { id: i.exercise_id, name: e?.name ?? "—", muscle: e?.primary_muscle ?? null, video: e?.video_url ?? null, instructions: e?.instructions ?? null },
          };
        }),
      })),
      logs: data.logs.map((l) => ({ item: l.block_item_id, week: l.week_no, weights: l.weights ?? l.reps.map(() => l.weight), reps: l.reps, rir: l.rir })),
      notes: data.notes.map((n) => ({ id: n.id, week: n.week_no, body: n.body })),
    };
  });
  return Response.json({ coaching: body }, { headers: { "Cache-Control": "private, no-store" } });
}
