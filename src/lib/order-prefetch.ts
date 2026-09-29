import "server-only";
import { batch, litList, type Tx } from "./db";

// تحميل مجمّع لبيانات الالتزام والمراجعات لعدة طلبات في رحلة واحدة (6 استعلامات مهما كان عدد المتدربين).
// لوحة الإدارة كانت تسأل قاعدة البيانات 6 مرات عن كل متدرب نشط، وكل سؤال رحلة شبكة إلى Neon.
// النتيجة تُحفظ مع المعاملة نفسها (WeakMap)، فتستفيد منها loadAdherence وloadWeekState بدون تغيير استدعائها.

export type BlockData = {
  id: string; start_date: string; weeks: number;
  items: { id: string; plan: unknown }[];
  logs: { week_no: number; n: number }[];
};
export type OrderProgressData = { blocks: BlockData[]; manual: Set<number>; checkins: string[]; rewarded: boolean };

const cache = new WeakMap<Tx, Map<string, OrderProgressData>>();

/** يحمّل بيانات الطلبات دفعة واحدة، ثم تقرأها loadOrderProgress من الذاكرة بدل استعلام لكل طلب */
export async function prefetchOrders(tx: Tx, orderIds: string[]): Promise<void> {
  if (!orderIds.length) return;
  const map = cache.get(tx) ?? new Map<string, OrderProgressData>();
  cache.set(tx, map);
  const ids = orderIds.filter((id) => !map.has(id));
  if (!ids.length) return;
  const idList = litList(tx, ids, "uuid");
  const [blocksR, itemsR, logsR, weeksR, checkinsR, rewardR] = await batch(tx, [
    `SELECT id, order_id, start_date::text AS start_date, weeks FROM blocks WHERE order_id = ANY(${idList})`,
    `SELECT d.block_id, i.id, i.plan FROM block_items i JOIN block_days d ON d.id = i.day_id JOIN blocks b ON b.id = d.block_id WHERE b.order_id = ANY(${idList})`,
    `SELECT d.block_id, l.week_no, count(DISTINCT l.block_item_id)::int AS n FROM item_logs l JOIN block_items i ON i.id = l.block_item_id
       JOIN block_days d ON d.id = i.day_id JOIN blocks b ON b.id = d.block_id WHERE b.order_id = ANY(${idList}) GROUP BY d.block_id, l.week_no`,
    `SELECT order_id, week_no FROM review_weeks WHERE order_id = ANY(${idList})`,
    `SELECT order_id, created_at FROM check_ins WHERE order_id = ANY(${idList})`,
    `SELECT order_id FROM loyalty_rewards WHERE order_id = ANY(${idList})`,
  ]);
  const blocks = blocksR.rows, items = itemsR.rows, logs = logsR.rows, weeks = weeksR.rows, checkins = checkinsR.rows;
  const rewarded = new Set(rewardR.rows.map((r) => r.order_id as string));
  for (const id of ids) {
    map.set(id, {
      blocks: blocks.filter((b) => b.order_id === id).map((b) => ({
        id: b.id, start_date: b.start_date, weeks: b.weeks,
        items: items.filter((i) => i.block_id === b.id).map((i) => ({ id: i.id, plan: i.plan })),
        logs: logs.filter((l) => l.block_id === b.id).map((l) => ({ week_no: l.week_no, n: l.n })),
      })),
      manual: new Set<number>(weeks.filter((w) => w.order_id === id).map((w) => w.week_no)),
      checkins: checkins.filter((c) => c.order_id === id).map((c) => c.created_at),
      rewarded: rewarded.has(id),
    });
  }
}

/** بيانات طلب واحد: من التحميل المجمّع إن وُجد، وإلا بالاستعلامات المنفردة (سلوك الصفحات الفردية كما هو) */
export async function loadOrderProgress(tx: Tx, orderId: string, want: { training?: boolean; reviews?: boolean; reward?: boolean } = { training: true, reviews: true, reward: true }): Promise<OrderProgressData> {
  const hit = cache.get(tx)?.get(orderId);
  if (hit) return hit;
  const out: OrderProgressData = { blocks: [], manual: new Set(), checkins: [], rewarded: false };
  if (want.training) {
    const blocks = (await tx.query(`SELECT id, start_date::text AS start_date, weeks FROM blocks WHERE order_id = $1`, [orderId])).rows;
    for (const b of blocks) {
      const items = (await tx.query(`SELECT i.id, i.plan FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1`, [b.id])).rows;
      const logs = (await tx.query(
        `SELECT l.week_no, count(DISTINCT l.block_item_id)::int AS n FROM item_logs l JOIN block_items i ON i.id = l.block_item_id
           JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1 GROUP BY l.week_no`, [b.id])).rows;
      out.blocks.push({ id: b.id, start_date: b.start_date, weeks: b.weeks, items, logs });
    }
  }
  if (want.reviews) {
    out.manual = new Set<number>((await tx.query("SELECT week_no FROM review_weeks WHERE order_id = $1", [orderId])).rows.map((x) => x.week_no));
    out.checkins = (await tx.query("SELECT created_at FROM check_ins WHERE order_id = $1", [orderId])).rows.map((x) => x.created_at);
  }
  if (want.reward) out.rewarded = (await tx.query("SELECT EXISTS (SELECT 1 FROM loyalty_rewards WHERE order_id = $1) AS x", [orderId])).rows[0].x as boolean;
  return out;
}
