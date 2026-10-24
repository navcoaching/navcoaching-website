import { test } from "node:test";
import assert from "node:assert/strict";
import { canon, matchLibrary, parseCell, parseProgram, programGuide, similarity, splitName } from "../../src/lib/program-import.ts";

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
  const c = (reps: number[], rir: number | null) => ({ reps, rir, range: null, side: false, secs: false });
  assert.deepEqual(parseCell("3x10 @2"), c([10, 10, 10], 2));
  assert.deepEqual(parseCell("3×12 RIR 1.5"), c([12, 12, 12], 1.5));
  assert.deepEqual(parseCell("12-10-8 @٠"), c([12, 10, 8], 0));
  assert.deepEqual(parseCell("3x10"), c([10, 10, 10], null));
  assert.deepEqual(parseCell("—"), c([], null));
  assert.deepEqual(parseCell(""), c([], null));
  assert.deepEqual(parseCell("2 × 15–20 لكل رجل"), { reps: [15, 15], rir: null, range: "15–20", side: true, secs: false });
  assert.deepEqual(parseCell("3 × 8–12"), { reps: [8, 8, 8], rir: null, range: "8–12", side: false, secs: false });
  assert.deepEqual(parseCell("3x30 ث"), { reps: [30, 30, 30], rir: null, range: null, side: false, secs: true });
  assert.equal(parseCell("10–15 د خفيف"), "duration");
  assert.equal(parseCell("3 × 20–15"), null);
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
  assert.equal(p.instructions, "• الإحماء: جولتان.\nالراحة: دقيقتين.");
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
  assert.match(all, /اليوم 1 \(A\): الجدول لا يغطي الأسبوع 3 والقالب 3 أسابيع/);
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


// جدول برنامج جاهز (مثل ملف «برنامج تمارين النادي»): أقسام نصية، «اليوم الأول»، أعمدة نطاق أسابيع، عمود RIR، سجل أسبوع يُتجاهل
const READY = `# برنامج تمارين النادي — متدربة

**الباقة الأساسية · 4 أسابيع · 3 أيام بالأسبوع**
برنامج يراعي الركبة

## بيانات المتدرب
- **العمر:** 38 سنة · التهاب أوتار الركبة

## قواعد السلامة (الأهم)
1. لا قفز ولا جري.

## الإحماء قبل كل جلسة
- **أ)** 5–10 دقائق دراجة.

## طريقة التعبئة
- **الأعمدة:** الوزن والتكرارات.

---

## اليوم الأول — جسم كامل (تركيز رباعية)

| # | التمرين | الأسبوع 1–2 | الأسبوع 3–4 | الإيقاع | RIR | الراحة | ملاحظات التنفيذ |
|---|---|---|---|---|---|---|---|
| 1 | Leg Extension (الظهر مائل للخلف) | 2 × 15–20 | 3 × 12–15 | نزول 3 ث | 2–3 | 90 ث | وزن خفيف |
| 2أ | Dumbbell Romanian Deadlift | 3 × 10–12 | 3 × 10–12 | — | 1–2 | سوبرست | |
| 3 | Standing Cable Hip Abduction | 2 × 15–20 لكل رجل | 3x12 @0 | متحكم | 1–2 | 60 ث | |
| 6 | دراجة ثابتة (اختياري) | 10 د خفيف | 10–15 د خفيف | — | — | — | |

**سوبرست:** التمرينان (أ) و(ب) متتاليين.

### سجل الأسبوع (يُنسخ لكل أسبوع)

| التمرين | الوزن (كغ) | مجموع التكرارات | RIR | ألم الركبة 0–10 |
|---|---|---|---|---|
| Leg Extension (الظهر مائل للخلف) |  |  |  |  |
| Standing Cable Hip Abduction |  |  |  |  |

*تم تصميم الجدول من قبل المدربة*`;

test("استيراد قالب: جدول برنامج جاهز", () => {
  const r = parseProgram(READY);
  assert.ok("program" in r, JSON.stringify(r));
  const p = r.program;
  assert.equal(p.name, "برنامج تمارين النادي — متدربة");
  assert.equal(p.weeks, 4);
  assert.equal(p.place, "نادي");
  assert.equal(p.days.length, 1);
  assert.equal(p.days[0].title, "جسم كامل (تركيز رباعية)");
  // سجل الأسبوع لا يُضاف كتمارين، والدراجة (مدة) تُترك مع ذكرها
  assert.deepEqual(p.days[0].items.map((i) => i.match), ["Leg Extension", "Dumbbell Romanian Deadlift", "Standing Cable Hip Abduction"]);
  assert.deepEqual(p.skipped, ["جسم كامل (تركيز رباعية): دراجة ثابتة (اختياري) (مدة وليس مجموعات)"]);
  const [ext, rdl, abd] = p.days[0].items;
  // الأسابيع 1–2 من العمود الأول بـ RIR الأعلى (3)، و3–4 من الثاني بالأدنى (2)
  assert.deepEqual(ext.plan, [{ sets: 2, reps: [15, 15], rir: 3 }, { sets: 2, reps: [15, 15], rir: 3 }, { sets: 3, reps: [12, 12, 12], rir: 2 }, { sets: 3, reps: [12, 12, 12], rir: 2 }]);
  assert.equal(ext.note, "الظهر مائل للخلف · التكرارات: 15–20 (الأسابيع 1–2)، 12–15 (الأسابيع 3–4) · الإيقاع: نزول 3 ث · الراحة: 90 ث · وزن خفيف");
  assert.equal(rdl.note, "التكرارات: 10–12 · الراحة: سوبرست");
  // RIR مكتوب في الخلية يتقدّم على عمود RIR
  assert.deepEqual(abd.plan.map((w) => w.rir), [2, 2, 0, 0]);
  assert.match(abd.note!, /^لكل جهة/);
  // التعليمات: المقدمة، ثم قواعد السلامة والإحماء (بدون بيانات المتدرب وطريقة التعبئة)، ثم ملاحظات الأيام
  const ins = p.instructions!;
  assert.match(ins, /^الباقة الأساسية · 4 أسابيع/);
  assert.match(ins, /قواعد السلامة \(الأهم\):\n1\. لا قفز ولا جري\./);
  assert.match(ins, /الإحماء قبل كل جلسة:\n• أ\) 5–10 دقائق دراجة\./);
  assert.match(ins, /سوبرست: التمرينان/);
  assert.match(ins, /تم تصميم الجدول من قبل المدربة$/);
  assert.doesNotMatch(ins, /العمر|التهاب|الأعمدة/);
  assert.ok(ins.indexOf("قواعد السلامة") < ins.indexOf("سوبرست"));
  // عمود الألم في «سجل الأسبوع»: التمارين المذكورة فيه فقط
  assert.deepEqual(p.days[0].items.map((i) => i.pain), ["ألم الركبة", null, "ألم الركبة"]);
  // ملاحظات المدربة: كل الأقسام مع بيانات المتدرب، بدون طريقة التعبئة
  assert.match(p.notes!, /بيانات المتدرب:\n• العمر: 38 سنة/);
  assert.match(p.notes!, /قواعد السلامة \(الأهم\):/);
  assert.doesNotMatch(p.notes!, /الأعمدة/);
});

test("استيراد قالب: الأسابيع غير المغطاة خطأ", () => {
  const r = parseProgram("# قالب\n- الأسابيع: 5\n## اليوم 1: A\n| التمرين | الأسبوع 1–2 | الأسبوع 3–4 |\n|---|---|---|\n| Squat | 3x5 | 3x5 |");
  assert.ok("errors" in r);
  assert.match(r.errors.join(), /لا يغطي الأسبوع 5/);
});

test("الاسم: الجزء الإنجليزي للمطابقة والباقي وصف", () => {
  assert.deepEqual(splitName("Goblet Squat إلى صندوق (Box)"), { match: "Goblet Squat", extra: "إلى صندوق · Box" });
  assert.deepEqual(splitName("Push-Ups مرتفعة (اليدين على مقعد)"), { match: "Push-Ups", extra: "مرتفعة · اليدين على مقعد" });
  assert.deepEqual(splitName("90s Transition"), { match: "90s Transition", extra: "" });
  assert.deepEqual(splitName("دراجة ثابتة"), { match: "دراجة ثابتة", extra: "" });
});

test("مطابقة المكتبة: ربط سابق، نفس الاسم والمرادفات، وإلا اقتراحات", () => {
  assert.equal(canon("Dumbbell Romanian Deadlift"), canon("DB RDL"));
  assert.equal(canon("Push-Ups"), canon("Push Up"));
  assert.equal(canon("Hip Thrust"), canon("Hip Thrusts"));
  const lib = [
    { id: "a", name: "DB RDL", place: "منزل" }, { id: "b", name: "Quads Leg Press", place: "نادي" }, { id: "c", name: "Mid Leg Press", place: "نادي" },
    { id: "d", name: "Hip Thrusts", place: "نادي" }, { id: "e", name: "Adductor Machine", place: "نادي" },
  ];
  const m = matchLibrary(["Dumbbell Romanian Deadlift", "Leg Press", "Hip Thrust", "Leg Press", "Hip Adduction Machine"], lib, { [canon("Hip Adduction Machine")]: "e" });
  assert.equal(m.length, 4); // «Leg Press» مرة واحدة
  assert.deepEqual(m.map((x) => [x.id, x.how]), [["a", "name"], [null, null], ["d", "name"], ["e", "alias"]]);
  assert.deepEqual(m[1].suggestions.map((s) => s.id).sort(), ["b", "c"]);
  // ربط لتمرين لم يعد في المكتبة يُهمل
  assert.equal(matchLibrary(["X Raise"], lib, { [canon("X Raise")]: "gone" })[0].id, null);
});

test("اقتراحات: نفس الجذر يُحسب تشابهاً", () => {
  assert.ok(similarity("Hip Adduction Machine", "Adductor Machine") > similarity("Hip Adduction Machine", "Hip Hinge"));
  const lib = ["Hip Hinge", "Hip Thrusts", "Adductor Machine", "Adductor Slides", "Hips Stretch"].map((name, i) => ({ id: String(i), name, place: "نادي" }));
  assert.equal(matchLibrary(["Hip Adduction Machine"], lib, {})[0].suggestions[0].name, "Adductor Machine");
  assert.equal(matchLibrary(["Standing Cable Hip Adduction"], lib, {})[0].suggestions[0].name.startsWith("Adductor"), true);
});
