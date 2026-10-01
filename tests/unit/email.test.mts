// قالب بريد العميل: الخطوات، المحتوى، والحماية من حقن HTML.
import { test } from "node:test";
import assert from "node:assert/strict";
import { esc, orderSteps, renderEmail, statusCopy } from "../../src/lib/email-template.ts";

const brand = { site: "https://navcoaching.com", whatsapp: "+966500000000", instagram: "https://instagram.com/nav", legalName: "مؤسسة ناف", cr: "7000000000" };
const order = { orderNo: "NAV-260927-ABCDE", createdAt: "2026-09-27T15:12:00Z", status: "preparing", category: "follow",
  product: "الباقة المكثفة", offer: "3 أشهر", amountHalalas: 155000, paymentMethod: "bank_transfer" };

test("خطوات الطلب حسب الحالة", () => {
  assert.deepEqual(orderSteps("awaiting_payment", "follow").map((s) => s.state), ["done", "now", "next", "next"]);
  assert.deepEqual(orderSteps("preparing", "follow").map((s) => s.state), ["done", "done", "now", "next"]);
  assert.deepEqual(orderSteps("active", "follow").map((s) => s.state), ["done", "done", "done", "done"]);
  assert.equal(orderSteps("delivered", "files")[3].label, "تم التسليم");
});
test("بريد تأكيد الطلب: ترحيب، عنوان، رقم الطلب، الملخص، والتذييل", () => {
  const c = statusCopy("preparing", "follow");
  const html = renderEmail({ name: "سارة", headline: c.headline, message: c.message, order, brand });
  for (const s of ["يا هلا وسهلا سارة", "نبشرك بتأكيد الطلب", "NAV-260927-ABCDE", "ملخص طلبك", "1,550 ر.س", "تحويل بنكي",
                   "https://navcoaching.com/account/orders/NAV-260927-ABCDE", "https://navcoaching.com/email/logo.png", "مؤسسة ناف", "wa.me/966500000000"]) {
    assert.ok(html.includes(s), `missing: ${s}`);
  }
  assert.match(html, /dir="rtl"/);
});
test("النصوص الديناميكية تُهرَّب", () => {
  const html = renderEmail({ name: "<script>x</script>", headline: "a", message: "b & <i>c</i>", brand });
  assert.ok(!html.includes("<script>x"));
  assert.ok(html.includes("b &amp; &lt;i&gt;c&lt;/i&gt;"));
  assert.equal(esc(`"'`), "&quot;&#39;");
});
test("بريد رمز الدخول بدون ملخص طلب", () => {
  const html = renderEmail({ headline: "رمز الدخول", code: "123456", message: "صالح 10 دقائق", brand });
  assert.ok(html.includes("123456"));
  assert.ok(!html.includes("ملخص طلبك"));
});
