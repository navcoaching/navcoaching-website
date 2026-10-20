// عرض التجديد بخصم 10% في آخر 5 أيام، وحالاته بعد طلب التجديد أو المكافأة.
import { test } from "node:test";
import assert from "node:assert/strict";
import { discounted, renewalState } from "../../src/lib/renewal.ts";

const o = { status: "active", category: "follow", months: 3 };
test("الخصم 10% مقرّب لأقرب هللة", () => {
  assert.equal(discounted(155000), 139500);
  assert.equal(discounted(34905), 31415);
});
test("العرض من 5 أيام قبل الانتهاء حتى يومه فقط", () => {
  assert.deepEqual(renewalState(o, 5, [], 155000), { kind: "offer", left: 5, price: 155000, discounted: 139500 });
  assert.equal(renewalState(o, 0, [], 1000)?.kind, "offer");
  assert.equal(renewalState(o, 6, [], 1000), null);
  assert.equal(renewalState(o, -1, [], 1000), null);
  assert.equal(renewalState({ ...o, category: "files" }, 3, [], 1000), null);
  assert.equal(renewalState({ ...o, status: "preparing" }, 3, [], 1000), null);
});
test("بعد طلب التجديد: بانتظار الدفع، ثم مجدَّد؛ والملغى يعيد العرض", () => {
  assert.deepEqual(renewalState(o, 3, [{ order_no: "N1", status: "awaiting_payment", renewal_kind: "renewal" }], 1000), { kind: "pending", orderNo: "N1", status: "awaiting_payment" });
  assert.deepEqual(renewalState(o, 3, [{ order_no: "N1", status: "active", renewal_kind: "renewal" }], 1000), { kind: "renewed", orderNo: "N1", reward: false });
  assert.equal(renewalState(o, 3, [{ order_no: "N1", status: "cancelled", renewal_kind: "renewal" }], 1000)?.kind, "offer");
  assert.deepEqual(renewalState(o, 3, [{ order_no: "R1", status: "active", renewal_kind: "reward" }], 1000), { kind: "renewed", orderNo: "R1", reward: true });
});
