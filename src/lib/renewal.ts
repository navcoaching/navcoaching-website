// عرض التجديد بخصم في آخر أيام الاشتراك. قاعدة البيانات (app.create_renewal) هي المتحققة من الفترة والسعر؛
// هذا الملف للعرض فقط وبنفس القيم.
import type { Tx } from "./db";

export const RENEWAL_PCT = 10;
export const RENEWAL_WINDOW_DAYS = 5;

export const discounted = (price: number) => Math.round((price * (100 - RENEWAL_PCT)) / 100);

export type Continuation = { order_no: string; status: string; renewal_kind: string };
export type RenewalInfo =
  | { kind: "offer"; left: number; price: number; discounted: number }
  | { kind: "pending"; orderNo: string; status: string }
  | { kind: "renewed"; orderNo: string; reward: boolean }
  | null;

/** حالة التجديد لاشتراك واحد. left = الأيام المتبقية حتى تاريخ الانتهاء (بتوقيت الرياض) */
export function renewalState(o: { status: string; category: string; months: number }, left: number | null,
                             conts: Continuation[], price: number): RenewalInfo {
  if (o.category !== "follow" || o.months <= 0 || left == null) return null;
  const live = conts.filter((c) => c.status !== "cancelled");
  const done = live.find((c) => ["active", "delivered", "completed"].includes(c.status));
  if (done) return { kind: "renewed", orderNo: done.order_no, reward: done.renewal_kind === "reward" };
  const pending = live.find((c) => c.renewal_kind === "renewal");
  if (pending) return { kind: "pending", orderNo: pending.order_no, status: pending.status };
  if (!["active", "delivered"].includes(o.status) || left < 0 || left > RENEWAL_WINDOW_DAYS) return null;
  return { kind: "offer", left, price, discounted: discounted(price) };
}

type RenewOrder = { id: string; status: string; category: string; months: number; offer_id?: string | null; list_price_halalas: number };
/** يحمّل طلبات التجديد/المكافأة والسعر الحالي لكل اشتراك */
export async function loadRenewals<T extends RenewOrder>(tx: Tx, orders: T[], leftOf: (o: T) => number | null) {
  const ids = orders.map((o) => o.id);
  const conts = (await tx.query(
    `SELECT renewal_of, order_no, status, renewal_kind FROM orders WHERE renewal_of = ANY($1::uuid[]) ORDER BY created_at DESC`, [ids])).rows;
  const prices = new Map<string, number>((await tx.query(
    `SELECT po.id, po.price_halalas FROM product_offers po JOIN products p ON p.id = po.product_id
      WHERE po.id = ANY($1::uuid[]) AND po.active AND p.status = 'published'`,
    [orders.map((o) => o.offer_id).filter(Boolean)])).rows.map((r) => [r.id, r.price_halalas]));
  return new Map(orders.map((o) => [o.id, renewalState(o, leftOf(o), conts.filter((c) => c.renewal_of === o.id),
    (o.offer_id && prices.get(o.offer_id)) || o.list_price_halalas)]));
}
