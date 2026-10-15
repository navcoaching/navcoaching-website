// الاختيار المتسلسل للتمارين: العضلة ← النمط ← النمط الفرعي ← الحركة التشريحية ← التصنيف الفرعي.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cascade, resetAfter, SUB_PATTERNS, PATTERNS } from "../../src/lib/exercises.ts";

const ex = [
  { name: "Back Squat", primary_muscle: "Q", pattern: "Squat", sub_pattern: "Free", anatomical_action: "KE+HE", movement_subcategory: null },
  { name: "Leg Press", primary_muscle: "Q", pattern: "Squat", sub_pattern: "Press", anatomical_action: "KE+HE", movement_subcategory: null },
  { name: "Leg Extension", primary_muscle: "Q", pattern: "Knee Ext", sub_pattern: "LE", anatomical_action: "KE", movement_subcategory: null },
  { name: "Bench", primary_muscle: "C", pattern: "Push", sub_pattern: "Flat", anatomical_action: "HA", movement_subcategory: "Flat" },
];

test("كل مستوى يضيّق الذي بعده فقط", () => {
  const all = cascade(ex, {});
  assert.deepEqual(all.options.primary_muscle, [{ value: "Q", count: 3 }, { value: "C", count: 1 }]);
  assert.equal(all.matches.length, 4);
  const q = cascade(ex, { primary_muscle: "Q" });
  assert.deepEqual(q.options.pattern.map((o) => o.value), ["Squat", "Knee Ext"]);
  assert.deepEqual(q.options.primary_muscle.length, 2); // المستوى نفسه لا يتضيّق
  const sq = cascade(ex, { primary_muscle: "Q", pattern: "Squat", sub_pattern: "Press" });
  assert.deepEqual(sq.matches.map((e) => e.name), ["Leg Press"]);
  assert.deepEqual(sq.options.movement_subcategory, []);
});
test("اختيار لم يعد متاحاً يُتجاهل، والتغيير يمسح ما بعده", () => {
  const r = cascade(ex, { primary_muscle: "C", pattern: "Squat" });
  assert.deepEqual(r.applied, { primary_muscle: "C" });
  assert.equal(r.matches.length, 1);
  assert.deepEqual(resetAfter({ primary_muscle: "Q", pattern: "Squat", sub_pattern: "Free" }, "pattern", "Knee Ext"), { primary_muscle: "Q", pattern: "Knee Ext" });
  assert.deepEqual(resetAfter({ primary_muscle: "Q", pattern: "Squat" }, "primary_muscle", ""), {});
});
test("كل نمط فرعي تابع لنمط حركة معروف", () => {
  for (const [, parent] of SUB_PATTERNS) assert.ok((PATTERNS as readonly string[]).includes(parent), parent);
});
