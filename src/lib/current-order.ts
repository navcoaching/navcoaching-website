import "server-only";
import { withUser } from "./db";

export type CurrentOrder = { order_no: string; training: boolean; nutrition: boolean };

/** الاشتراك الحالي للمتدرب: أحدث طلب متابعة فعّال (النشط أولاً)، وهل له برنامج تمرين وتغذية */
export async function loadCurrentOrder(userId: string): Promise<CurrentOrder | undefined> {
  return withUser(userId, async (tx) => (await tx.query(
    `SELECT o.order_no,
            EXISTS (SELECT 1 FROM blocks b WHERE b.order_id = o.id) AS training,
            (EXISTS (SELECT 1 FROM nutrition_targets t WHERE t.order_id = o.id)
              OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.order_id = o.id AND NOT p.archived)
              OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.order_id = o.id AND NOT r.archived)) AS nutrition
       FROM orders o
      WHERE o.user_id = $1 AND o.category = 'follow' AND o.status IN ('active', 'delivered', 'completed')
      ORDER BY (o.status = 'active') DESC, o.sub_start_at DESC NULLS LAST, o.created_at DESC LIMIT 1`, [userId])).rows[0]);
}
