import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { loadCurrentOrder } from "@/lib/current-order";
import { loadAllLifts, loadBodyData } from "@/lib/program-data";
import { currentWeek, personalRecords } from "@/lib/training";
import { riyadhDate } from "@/lib/schedule";

export const dynamic = "force-dynamic";

// التقدم للمتدرب في التطبيق: الوزن والقياسات والأرقام القياسية من برامج المدربة، وخطوات البرنامج الحالي
export async function GET() {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const cur = await loadCurrentOrder(user.id);
  const body = await withUser(user.id, async (tx) => {
    const block = cur ? (await tx.query(
      `SELECT b.id, b.start_date::text, b.weeks, b.steps_goal_week, b.status FROM blocks b JOIN orders o ON o.id = b.order_id
        WHERE o.order_no = $1 AND o.user_id = $2 ORDER BY (b.status = 'active') DESC, b.created_at DESC LIMIT 1`, [cur.order_no, user.id])).rows[0] : null;
    const steps = block ? (await tx.query(`SELECT week_no, total FROM step_logs WHERE block_id = $1 ORDER BY week_no`, [block.id])).rows : [];
    return {
      today: riyadhDate(),
      order_no: cur?.order_no ?? null,
      body: await loadBodyData(tx, user.id),
      records: personalRecords(await loadAllLifts(tx, user.id)),
      steps: block ? {
        block: block.id, goal_week: block.steps_goal_week, weeks: block.weeks, read_only: block.status !== "active",
        current_week: currentWeek(block.start_date, riyadhDate(), block.weeks), logs: steps,
      } : null,
    };
  });
  return Response.json({ progress: body }, { headers: { "Cache-Control": "private, no-store" } });
}
