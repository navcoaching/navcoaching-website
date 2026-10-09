// كشف طلب باسم شخص غير صاحب الحساب.
import { test } from "node:test";
import assert from "node:assert/strict";
import { differentPerson, normName } from "../../src/lib/names.ts";

test("التطبيع العربي", () => {
  assert.equal(normName("  سارَة  "), "ساره");
  assert.equal(normName("أمل"), normName("امل"));
  assert.equal(normName("ليلى"), "ليلي");
});
test("نفس الشخص لا يُعتبر اختلافاً", () => {
  assert.equal(differentPerson("سارة", "ساره محمد"), false);
  assert.equal(differentPerson("سارة العتيبي", "سارة"), false);
  assert.equal(differentPerson("Sarah", "sarah ali"), false);
  assert.equal(differentPerson("", "غيداء"), false);
  assert.equal(differentPerson("sara.q", "غيداء", "sara.q@gmail.com"), false);
  // لاتيني مقابل عربي: ما نحكم
  assert.equal(differentPerson("Sarah", "غيداء"), false);
});
test("شخصان مختلفان", () => {
  assert.equal(differentPerson("سارة", "غيداء"), true);
  assert.equal(differentPerson("سارة أحمد", "غيداء سعد"), true);
  assert.equal(differentPerson("Sarah", "Ghaida"), true);
});
