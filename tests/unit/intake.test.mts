// اختبارات وحدة لقواعد الاستبيان وحسابات الاشتراك (تعمل على Node مباشرة بدون خادم).
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { intakeSchema, splitIntake, OPT, EXPECTATIONS_Q } from "../../src/lib/intake.ts";
import { reviewWeeks, weekStatuses, subscriptionState, addDays, fillTemplate } from "../../src/lib/schedule.ts";

const valid = {
  idempotency_key: "k".repeat(20), sku: "int1", name: "سارة", cc: "+966", phone: "512345678", gender: OPT.gender[0], age: "29",
  goal: OPT.goal[0], level: OPT.level[0], place: OPT.place[0], equip: [], days: OPT.days[0], duration: OPT.duration[0],
  injury: "لا", condition: "لا", health_ack: "on", weight: "70", height: "165", calories: OPT.calories[0],
  expectations: "متابعة أسبوعية", media: OPT.media[0], consent_terms: "on", consent_wa: "on",
};
const errs = (o: Record<string, unknown>) => {
  const r = intakeSchema.safeParse(o);
  return r.success ? {} : Object.fromEntries(r.error.issues.map((i) => [String(i.path[0]), i.message]));
};

describe("الاستبيان", () => {
  test("إجابة صحيحة كاملة تُقبل والعمر رقم دقيق", () => {
    const r = intakeSchema.parse(valid);
    assert.equal(r.age, 29);
    const { answers, health } = splitIntake(r);
    assert.equal(answers.age, 29);
    assert.equal(answers.expectations, "متابعة أسبوعية");
    assert.equal(health.weight, 70);
    assert.equal(EXPECTATIONS_Q, "ماذا تتوقع مني أثناء التدريب؟");
  });
  test("العمر: رقم صحيح بين 10 و 90 فقط", () => {
    for (const age of ["9", "91", "25.5", "abc", "", "25 – 34"]) assert.ok(errs({ ...valid, age }).age, age);
    for (const age of ["10", "90"]) assert.equal(errs({ ...valid, age, guardian_ok: "on" }).age, undefined, age);
  });
  test("أقل من 18 يحتاج موافقة ولي الأمر", () => {
    assert.ok(errs({ ...valid, age: "16" }).guardian_ok);
    assert.equal(errs({ ...valid, age: "16", guardian_ok: "on" }).guardian_ok, undefined);
  });
  test("الوزن والطول إلزاميان وبنطاق واقعي", () => {
    for (const weight of ["", "29", "251"]) assert.ok(errs({ ...valid, weight }).weight, weight);
    for (const height of ["", "119", "231"]) assert.ok(errs({ ...valid, height }).height, height);
  });
  test("سؤال التوقعات إلزامي", () => {
    assert.ok(errs({ ...valid, expectations: "" }).expectations);
    assert.ok(errs({ ...valid, expectations: "  " }).expectations);
  });
});

describe("الاشتراك والمراجعات الأسبوعية", () => {
  const today = "2026-09-26"; // سبت
  test("حالات الاشتراك", () => {
    const s = (start: string | null, end: string | null, status = "active") => subscriptionState({ status, sub_start_at: start && `${start}T09:00:00Z`, sub_end_at: end && `${end}T09:00:00Z` }, 7, today);
    assert.equal(s(null, null), "not_started");
    assert.equal(s("2026-09-01", "2026-12-01"), "active");
    assert.equal(s("2026-09-01", "2026-10-03"), "ending_soon");
    assert.equal(s("2026-06-01", "2026-09-25"), "expired");
    assert.equal(s("2026-09-01", "2026-12-01", "completed"), "expired");
    assert.equal(s("2026-09-01", "2026-12-01", "cancelled"), "cancelled");
  });
  test("أسابيع المراجعة: أول موعد بعد أسبوع من البدء ثم كل 7 أيام حتى النهاية", () => {
    const w = reviewWeeks("2026-09-01T09:00:00Z", "2026-10-01T09:00:00Z", 2 /* الثلاثاء */, 2);
    assert.deepEqual(w.map((x) => x.due), ["2026-09-08", "2026-09-15", "2026-09-22", "2026-09-29"]);
    assert.equal(w[0].windowEnd, "2026-09-10");
  });
  test("حالة كل أسبوع: يدوي، من الموقع، فائت، حالي", () => {
    const w = reviewWeeks("2026-09-01T09:00:00Z", "2026-10-01T09:00:00Z", 2, 2);
    const st = weekStatuses(w, new Set([1]), ["2026-09-21T10:00:00Z"], today);
    assert.deepEqual(st.map((x) => x.status), ["done", "missed", "done", "current"]);
    assert.deepEqual(st.map((x) => x.source), ["manual", null, "site", null]);
    assert.equal(addDays("2026-02-28", 1), "2026-03-01");
  });
  test("القوالب تُملأ بالمتغيرات", () => {
    assert.equal(fillTemplate("مرحباً {name} {x}", { name: "نورة" }), "مرحباً نورة {x}");
  });
});
