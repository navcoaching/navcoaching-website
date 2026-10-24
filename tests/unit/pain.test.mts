import { test } from "node:test";
import assert from "node:assert/strict";
import { painApplies, painLabelFrom, painTone } from "../../src/lib/pain.ts";

test("اسم مقياس الألم من عنوان العمود", () => {
  assert.equal(painLabelFrom("ألم الركبة 0–10"), "ألم الركبة");
  assert.equal(painLabelFrom("ألم المرفق (0-10)"), "ألم المرفق");
  assert.equal(painLabelFrom("Pain 0-10"), "Pain");
  assert.equal(painLabelFrom("الألم"), "الألم");
  assert.equal(painLabelFrom("RIR"), null);
  assert.equal(painLabelFrom("مجموع التكرارات"), null);
});

test("المقياس فقط للتمارين اللي تحمّل منطقة الشكوى", () => {
  assert.ok(painApplies("ألم الركبة", "Quadriceps / الأمامية"));
  assert.ok(painApplies("ألم الركبة", "Adductors / الأفخاذ الداخلية"));
  assert.ok(painApplies("ألم الركبة", "Calves / البطات"));
  assert.ok(!painApplies("ألم الركبة", "Chest / الصدر"));
  assert.ok(!painApplies("ألم الركبة", "Back & Lats / الظهر واللاتس"));
  assert.ok(painApplies("ألم المرفق", "Triceps / الترايسبس"));
  assert.ok(!painApplies("ألم المرفق", "Hamstrings / الخلفية"));
  assert.ok(painApplies("ألم الكتف", "Back & Lats / الظهر واللاتس"));
  assert.ok(!painApplies("ألم الكتف", "Lower back / أسفل الظهر"));
  // منطقة غير معروفة: كما في الملف
  assert.ok(painApplies("الألم", "Chest / الصدر"));
});

test("درجات الألم", () => {
  assert.deepEqual([0, 2, 3, 5, 6, 10].map(painTone), ["ok", "ok", "mid", "mid", "hi", "hi"]);
});
