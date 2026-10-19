// الالتزام الأسبوعي (تمرين + مراجعة) والـ streak واستحقاق مكافأة 3 أشهر.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { computeAdherence } from "../../src/lib/adherence.ts";
import { addDays } from "../../src/lib/schedule.ts";

const START = "2026-01-01";
const END = "2026-04-01";
const day = (n: number) => addDays("2026-01-01", n);
/** n أسبوعاً: تمرين logged/10 ومراجعة منجزة لكل أسبوع حسب الدالة */
function build(n: number, logged: (k: number) => number, done: (k: number) => boolean = () => true) {
  const training = Array.from({ length: n }, (_, i) => ({ start: day(7 * i), logged: logged(i + 1), total: 10 }));
  const reviews = Array.from({ length: n }, (_, i) => ({ no: i + 1, status: done(i + 1) ? "done" as const : "missed" as const }));
  return { training, reviews };
}

describe("الالتزام", () => {
  test("الأسابيع المكتملة فقط، ودرجة الأسبوع = متوسط التمرين والمراجعة", () => {
    const { training, reviews } = build(3, () => 8, (k) => k !== 2);
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(20), training, reviews });
    assert.equal(a.weeks.length, 2); // الأسبوع الثالث لم ينتهِ (ينتهي يوم 21)
    assert.deepEqual(a.weeks.map((w) => w.score), [0.9, 0.4]);
    assert.ok(Math.abs(a.avg! - 0.65) < 1e-9);
    assert.equal(a.streak, 0);
  });
  test("أسبوع بدون برنامج ولا مراجعة لا يُحسب، والمكوّن الموجود وحده يكفي", () => {
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(21),
      training: [{ start: day(7), logged: 5, total: 10 }], reviews: [{ no: 3, status: "done" }] });
    assert.deepEqual(a.weeks.map((w) => w.score), [null, 0.5, 1]);
    assert.equal(a.scored, 2);
    assert.equal(a.streak, 1);
  });
  test("الـ streak: الأسابيع المتتالية الأخيرة ≥ 90%", () => {
    const { training, reviews } = build(6, (k) => (k === 2 ? 5 : 9));
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(42), training, reviews });
    assert.equal(a.streak, 4);
  });
  test("المراجعة القادمة أو الحالية لا تُحسب ضد المتدرب", () => {
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(8),
      training: [{ start: day(0), logged: 10, total: 10 }], reviews: [{ no: 1, status: "current" }] });
    assert.equal(a.weeks[0].score, 1);
  });
});

describe("استحقاق المكافأة", () => {
  test("12 أسبوعاً بمتوسط 90% بالضبط: مستحق", () => {
    const { training, reviews } = build(12, () => 8); // (0.8 + 1) / 2 = 0.9
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(84), training, reviews });
    assert.equal(a.scored, 12);
    assert.equal(a.eligible, true);
    assert.equal(a.weeksLeft, 0);
  });
  test("89% لا يستحق", () => {
    const { training, reviews } = build(12, (k) => (k === 1 ? 5 : 8)); // (11×0.9 + 0.75)/12 ≈ 0.8875
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(84), training, reviews });
    assert.ok(a.avg! < 0.9 && a.avg! > 0.88);
    assert.equal(a.eligible, false);
  });
  test("11 أسبوعاً فقط: لم يحن بعد", () => {
    const { training, reviews } = build(12, () => 10);
    const a = computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(83), training, reviews });
    assert.equal(a.scored, 11);
    assert.equal(a.eligible, false);
    assert.equal(a.weeksLeft, 1);
  });
  test("باقة شهر أو اشتراك مكافأة: لا مكافأة", () => {
    const { training, reviews } = build(12, () => 10);
    assert.equal(computeAdherence({ subStart: START, subEnd: END, months: 1, today: day(84), training, reviews }).eligible, false);
    assert.equal(computeAdherence({ subStart: START, subEnd: END, months: 3, today: day(84), training, reviews, isReward: true }).eligible, false);
  });
});
