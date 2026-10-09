import { test } from "node:test";
import assert from "node:assert/strict";
import { latin, stepOf, toFields, validateStep, type Answers, type CheckoutData } from "../src/lib/checkout.ts";

const d = {
  sku: "int3", offers: [], defaultName: "", email: "", responseTime: "", opt: {}, ageMin: 10, ageMax: 90, nutritionSkus: ["int3"],
  questions: {}, startRange: { min: "2026-10-08", max: "2026-11-07" },
  custom: [{ id: "qabcd12", step: 2, type: "text", label: "سؤال", hint: "", options: [], required: true }],
} as CheckoutData;

test("checkout: step validation mirrors the site rules", () => {
  assert.deepEqual(Object.keys(validateStep(1, { sku: "int3" }, d)).sort(), ["age", "gender", "name", "phone"]);
  const ok1: Answers = { sku: "int3", name: "سارة", cc: "+966", phone: "0512345678", gender: "أنثى", age: "٢٥" };
  assert.deepEqual(validateStep(1, ok1, d), {});
  assert.ok(validateStep(1, { ...ok1, phone: "412345678" }, d).phone);
  assert.ok(validateStep(1, { ...ok1, cc: "+971", phone: "501234567" }, d).phone === undefined);
  assert.ok(validateStep(1, { ...ok1, age: "16" }, d).guardian_ok);
  assert.deepEqual(validateStep(1, { ...ok1, age: "16", guardian_ok: "on" }, d), {});
  assert.ok(validateStep(1, { ...ok1, age: "9" }, d).age);
  // سؤال إضافي مطلوب في خطوته
  const s2 = validateStep(2, { goal: "x", level: "x", place: "x", days: "x", duration: "x" }, d);
  assert.deepEqual(Object.keys(s2), ["cq_qabcd12"]);
  assert.equal(validateStep(3, { injury: "لا", condition: "لا" }, d).health_ack !== undefined, true);
  // باقة فيها تغذية: خبرة السعرات مطلوبة
  assert.deepEqual(Object.keys(validateStep(4, { weight: "٧٠٫٥", height: "165" }, d)), ["calories"]);
  assert.ok(validateStep(4, { weight: "20", height: "165", calories: "x" }, d).weight);
  assert.deepEqual(Object.keys(validateStep(5, { start_mode: "date" }, d)).sort(), ["consent_terms", "consent_wa", "expectations", "media", "start_date"]);
  assert.equal(stepOf("weight", d), 4);
  assert.equal(stepOf("cq_qabcd12", d), 2);
  assert.equal(stepOf("consent_wa", d), 5);
});

test("checkout: fields sent like the site form", () => {
  assert.equal(latin("٧٠٫٥"), "70.5");
  const f = toFields({ sku: "int3", gender: "ذكر", pregnancy: "حامل", place: "نادي", equip: ["دمبلز"], injury: "لا", condition: "لا",
    health_notes: "x", weight: "٧٠", prev_coach: "لا", prev_why: "y", start_mode: "asap", start_date: "2026-10-10", notes: "" });
  const keys = f.map(([k]) => k);
  for (const k of ["pregnancy", "equip", "health_notes", "prev_why", "start_date", "notes"]) assert.ok(!keys.includes(k), k);
  assert.deepEqual(f.find(([k]) => k === "weight"), ["weight", "70"]);
  assert.deepEqual(f.find(([k]) => k === "cc"), ["cc", "+966"]);
  const g = toFields({ gender: "أنثى", place: "البيت", equip: ["دمبلز", "بنش"], cc: "+971" });
  assert.deepEqual(g.filter(([k]) => k === "equip").map(([, v]) => v), ["دمبلز", "بنش"]);
});
