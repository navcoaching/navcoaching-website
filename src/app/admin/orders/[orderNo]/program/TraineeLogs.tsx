import { withUser } from "@/lib/db";
import { loadAllLifts, loadBlockData, loadBodyData, type BlockRow } from "@/lib/program-data";
import DayLogTable from "@/components/training/DayLogTable";
import ProgressView from "@/components/training/ProgressView";

/** سجلات المتدرب وتقدمه (للمدربة) */
export default async function TraineeLogs({ coachId, blockId, userId }: { coachId: string; blockId: string; userId: string }) {
  const { data, body, lifts } = await withUser(coachId, async (tx) => {
    const { rows: [b] } = await tx.query(
      `SELECT id, order_id, user_id, name, start_date::text, weeks, instructions, steps_goal_week, status FROM blocks WHERE id = $1`, [blockId]);
    return { data: await loadBlockData(tx, b as BlockRow), body: await loadBodyData(tx, userId), lifts: await loadAllLifts(tx, userId) };
  });
  return (
    <section className="stack" style={{ ["--space" as string]: "14px" }} data-testid="trainee-logs">
      <h2 style={{ fontSize: 19 }}>سجلات المتدرب</h2>
      {data.days.map((d) => (
        <details key={d.id} className="card" open={data.logs.some((l) => d.items.some((i) => i.id === l.block_item_id))}>
          <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>{d.title}</summary>
          <DayLogTable data={data} dayId={d.id} />
        </details>
      ))}
      <ProgressView data={data} body={body} lifts={lifts} />
    </section>
  );
}
