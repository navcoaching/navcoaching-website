// اختبار «أي باقة تناسبني؟»: المبتدئ حسب احتياجه ونوع المتابعة.
import { test } from "node:test";
import assert from "node:assert/strict";
import { recommend } from "../../src/lib/quiz.ts";

const r = (level: string, need: string, follow: string, live = "no") => recommend({ level, need, follow, live }).k;

test("المبتدئ: تغذية فقط ← باقة التغذية", () => {
  assert.equal(r("beg", "food", "weekly"), "nut");
  assert.equal(r("beg", "food", "none"), "nut");
  assert.equal(r("beg", "food", "close"), "nut");
});
test("المبتدئ بدون مكالمات أو بدون متابعة أسبوعية ← المتقدمة (تمرين وتغذية)", () => {
  assert.equal(r("beg", "both", "weekly"), "adv");
  assert.equal(r("beg", "both", "none"), "adv");
});
test("المبتدئ: تمرين فقط ← الأساسية، ومع زوم ← المكثفة", () => {
  assert.equal(r("beg", "train", "weekly"), "bas");
  assert.equal(r("beg", "train", "none"), "bas");
  assert.equal(r("beg", "both", "close"), "int");
  assert.equal(r("beg", "train", "close"), "int");
});
test("المبتدئ لا يُقترح له ملف بدون متابعة، وغيره يُقترح", () => {
  for (const need of ["both", "train", "food"]) assert.ok(!["diy", "diyN", "cN"].includes(r("beg", need, "none")));
  assert.equal(r("mid", "both", "none"), "diyN");
  assert.equal(r("adv", "train", "none"), "diy");
  assert.equal(r("mid", "food", "none"), "cN");
});
test("الجلسة الحضورية ← المكثفة دائماً، والأسئلة المحددة ← استشارة", () => {
  assert.equal(r("beg", "food", "weekly", "yes"), "int");
  assert.equal(r("beg", "askN", ""), "cN");
  assert.equal(r("adv", "askT", ""), "cT");
});
test("غير المبتدئ بدون تغيير", () => {
  assert.equal(r("mid", "both", "weekly"), "adv");
  assert.equal(r("mid", "train", "weekly"), "bas");
  assert.equal(r("adv", "food", "weekly"), "nut");
  assert.equal(r("mid", "both", "close"), "int");
});
