import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCell, parseProgram, programGuide } from "../../src/lib/program-import.ts";

const SAMPLE = `\`\`\`markdown
# اسم القالب: متوسط — يومين

- الأسابيع: ٣
- المكان: البيت

## التعليمات
- الإحماء: جولتان.
الراحة: دقيقتين.

## اليوم 1: UPPER
| التمرين | الأسبوع 1 | الأسبوع 2 | الأسبوع 3 | ملاحظة |
|---|:---:|---|---|---|
| **Push Up** | 3x10 @3 | 3×12 RIR 2 | 12-10-8 @1 | نزول بطيء |
| DB Lateral Raise | 2x15 | — | 2x15 | |

## LOWER
| التمرين | الخطة |
|---|---|
| Single Leg Squat | 4x8 @2 |
\`\`\``;

test("خلية الأسبوع", () => {
  assert.deepEqual(parseCell("3x10 @2"), { reps: [10, 10, 10], rir: 2 });
  assert.deepEqual(parseCell("3×12 RIR 1.5"), { reps: [12, 12, 12], rir: 1.5 });
  assert.deepEqual(parseCell("12-10-8 @٠"), { reps: [12, 10, 8], rir: 0 });
  assert.deepEqual(parseCell("3x10"), { reps: [10, 10, 10], rir: null });
  assert.deepEqual(parseCell("—"), { reps: [], rir: null });
  assert.deepEqual(parseCell(""), { reps: [], rir: null });
  assert.equal(parseCell("ثلاث جولات"), null);
  assert.equal(parseCell("3x10 @20"), null);
  assert.equal(parseCell("11x10"), null);
});

test("استيراد قالب: الصيغة الكاملة", () => {
  const r = parseProgram(SAMPLE);
  assert.ok("program" in r, JSON.stringify(r));
  const p = r.program;
  assert.equal(p.name, "متوسط — يومين");
  assert.equal(p.weeks, 3);
  assert.equal(p.place, "منزل");
  assert.equal(p.instructions, "الإحماء: جولتان.\nالراحة: دقيقتين.");
  assert.deepEqual(p.days.map((d) => d.title), ["UPPER", "LOWER"]);
  const [push, lat] = p.days[0].items;
  assert.equal(push.name, "Push Up");
  assert.equal(push.note, "نزول بطيء");
  assert.deepEqual(push.plan, [{ sets: 3, reps: [10, 10, 10], rir: 3 }, { sets: 3, reps: [12, 12, 12], rir: 2 }, { sets: 3, reps: [12, 10, 8], rir: 1 }]);
  // بدون RIR ← 3·2·1 حسب الأسبوع، و«—» أسبوع فارغ
  assert.deepEqual(lat.plan, [{ sets: 2, reps: [15, 15], rir: 3 }, { sets: 0, reps: [], rir: null }, { sets: 2, reps: [15, 15], rir: 1 }]);
  assert.equal(lat.note, null);
  // عمود «الخطة» الواحد يُطبّق على كل الأسابيع
  assert.equal(p.days[1].items[0].plan.length, 3);
  assert.ok(p.days[1].items[0].plan.every((w) => w.reps.join() === "8,8,8,8" && w.rir === 2));
});

test("استيراد قالب: عدد الأسابيع من الجدول إذا لم يُكتب", () => {
  const r = parseProgram("# قالب\n## اليوم 1: A\n| التمرين | الأسبوع 1 | الأسبوع 2 |\n|---|---|---|\n| Squat | 3x5 | 3x5 |");
  assert.ok("program" in r);
  assert.equal(r.program.weeks, 2);
  assert.equal(r.program.place, "نادي");
});

test("استيراد قالب: الأخطاء بمكانها ولا شيء يُنشأ", () => {
  const r = parseProgram("- الأسابيع: 3\n## اليوم 1: A\n| التمرين | الأسبوع 1 | الأسبوع 2 |\n|---|---|---|\n| Squat | 3x5 | 3x5 |\n## اليوم 2: B\n| التمرين | الأسبوع 1 | الأسبوع 2 | الأسبوع 3 |\n|---|---|---|---|\n| Row | كثير | 3x5 | 3x5 |\n| Curl | — | — | — |");
  assert.ok("errors" in r);
  const all = r.errors.join("\n");
  assert.match(all, /اسم القالب/);
  assert.match(all, /اليوم 1 \(A\): في الجدول 2 أسابيع والقالب 3/);
  assert.match(all, /اليوم 2 \(B\) · Row · الأسبوع 1: «كثير» غير مفهوم/);
  assert.match(all, /Curl: لا توجد مجموعات/);
  assert.ok("errors" in parseProgram(""));
  assert.ok("errors" in parseProgram("# قالب\n- الأسابيع: 20\n## اليوم 1: A\n| التمرين | الخطة |\n|---|---|\n| Squat | 3x5 |"));
});

test("دليل الصيغة: القواعد ومثال يُستورد وأسماء المكتبة", () => {
  const g = programGuide([{ name: "Push Up", primary_muscle: "Chest / الصدر", place: "منزل" }, { name: "Lat Pulldown", primary_muscle: "Back / الظهر", place: "نادي" }]);
  assert.match(g, /### Chest \/ الصدر\n- Push Up \(بيت\)/);
  assert.match(g, /### Back \/ الظهر\n- Lat Pulldown/);
  // المثال داخل الدليل يُستورد كما هو
  const example = g.split("```markdown")[1].split("```")[0];
  const r = parseProgram(example);
  assert.ok("program" in r, JSON.stringify(r));
  assert.deepEqual(r.program.days[0].items.map((i) => i.name), ["Push Up", "Lat Pulldown"]);
});
