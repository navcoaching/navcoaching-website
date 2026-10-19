import { test } from "node:test";
import assert from "node:assert/strict";
import { META_MAX, productDescription } from "../../src/lib/seo.ts";

const base = { name: "باقة القيمرز", category: "follow", audience: "اللاعبون الإلكترونيون, صانعوا المحتوى.", items: [{ text: "برنامج تمرين مخصص", included: true }, { text: "جدول تغذية", included: true }, { text: "غير مضمّن", included: false }], offers: [{ price_halalas: 39900, active: true }, { price_halalas: 25000, active: true }, { price_halalas: 10000, active: false }] };

test("وصف الباقة: جملة كاملة بالسعر الأدنى للعروض الفعّالة، وضمن الحد", () => {
  const d = productDescription(base);
  assert.ok(d.length <= META_MAX, `${d.length}`);
  assert.match(d, /باقة القيمرز/);
  assert.match(d, /لمن تناسب: اللاعبون الإلكترونيون/);
  assert.match(d, /تبدأ من 250 ريال/); // بدون العرض غير الفعّال
  assert.match(d, /تشمل برنامج تمرين مخصص، جدول تغذية/);
  assert.doesNotMatch(d, /غير مضمّن/);
});
test("وصف الباقة: طويل جداً يُقص مع بقاء السعر، وبدون عروض لا سعر", () => {
  const long = productDescription({ ...base, audience: "ا".repeat(300) });
  assert.ok(long.length <= META_MAX && long.endsWith("ريال."), long);
  const none = productDescription({ ...base, offers: [] });
  assert.doesNotMatch(none, /ريال/);
});
