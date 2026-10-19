// أسئلة الاستبيان القابلة للتعديل: قراءة الإعداد بأمان، بناؤه من نموذج الإدارة، والتحقق من الأسئلة الإضافية.
import { test } from "node:test";
import assert from "node:assert/strict";
import { BUILTIN_QUESTIONS, activeCustom, configFromForm, hintOf, isHidden, labelOf, parseConfig, validateCustomAnswers, customField } from "../../src/lib/intake-config.ts";

const form = (o: Record<string, string>) => (k: string) => o[k] ?? "";

test("الافتراضي: نصوص الأسئلة الأصلية، ولا شي مخفي", () => {
  const cfg = parseConfig(undefined);
  assert.equal(labelOf(cfg, "goal"), "هدفك الرئيسي");
  assert.equal(labelOf(cfg, "expectations"), "ماذا تتوقع مني أثناء التدريب؟");
  assert.equal(isHidden(cfg, "city"), false);
  assert.equal(BUILTIN_QUESTIONS.length, 29);
});

test("قراءة آمنة: مفاتيح غريبة وأنواع خاطئة تُتجاهل، والإخفاء للاختياري فقط", () => {
  const cfg = parseConfig({ labels: { goal: { label: "  وش هدفك؟  ", hint: "اختر الأقرب", hidden: true }, city: { hidden: true }, hack: { label: "x" } },
    custom: [{ id: "abcd12", type: "text", label: "سؤال", step: 9 }, { id: "BAD!", type: "text", label: "x" }, { id: "zzzz99", type: "choice", label: "ق", options: ["واحد"] }, { id: "abcd12", type: "long", label: "مكرر" }] });
  assert.equal(labelOf(cfg, "goal"), "وش هدفك؟");
  assert.equal(hintOf(cfg, "goal"), "اختر الأقرب");
  assert.equal(isHidden(cfg, "goal"), false); // مطلوب، ما ينخفى
  assert.equal(isHidden(cfg, "city"), true);
  assert.equal("hack" in cfg.labels, false);
  assert.deepEqual(cfg.custom.map((c) => [c.id, c.step]), [["abcd12", 5]]); // خطوة غير صالحة ← 5؛ معرّف سيئ، اختيار بخيار واحد، مكرر ← مرفوض
});

test("prev_why يتبع prev_coach في الإخفاء", () => {
  assert.equal(isHidden(parseConfig({ labels: { prev_coach: { hidden: true } } }), "prev_why"), true);
});

test("من نموذج الإدارة: النص المطابق للأصلي لا يُحفظ، والسؤال بدون نص يُحذف، والاختيار يحتاج خيارين", () => {
  const ok = configFromForm(form({
    l_goal: "هدفك الرئيسي", l_level: "كم مستواك؟", h_level: "اختر بصدق", x_city: "on", x_goal: "on",
    c0_label: "وش رياضتك المفضلة؟", c0_type: "choice", c0_options: "جري\nحديد\n\n", c0_step: "2", c0_req: "on", c0_active: "on",
    c1_label: "", c1_type: "text",
  }));
  assert.ok("config" in ok);
  if (!("config" in ok)) return;
  assert.deepEqual(ok.config.labels, { level: { label: "كم مستواك؟", hint: "اختر بصدق" }, city: { hidden: true } });
  assert.equal(ok.config.custom.length, 1);
  assert.deepEqual([ok.config.custom[0].options, ok.config.custom[0].step, ok.config.custom[0].required, ok.config.custom[0].active], [["جري", "حديد"], 2, true, true]);
  assert.match(ok.config.custom[0].id, /^q[a-z0-9]{6}$/);
  assert.ok("error" in configFromForm(form({ c0_label: "س", c0_type: "choice", c0_options: "واحد" })));
  assert.ok("error" in configFromForm(form({ c0_label: "س", c0_type: "zzz" })));
  assert.ok("error" in configFromForm(form({ l_goal: "ن".repeat(200) })));
  // المعرّف الموجود يبقى (حتى تبقى الإجابات القديمة مرتبطة)
  const again = configFromForm(form({ c0_label: "س", c0_type: "text", c0_id: "keep42", c0_active: "on" }));
  assert.ok("config" in again && again.config.custom[0].id === "keep42");
});

test("التحقق من الإجابات الإضافية: مطلوب، خيار صالح، نعم/لا، الطول، وغير النشط يُتجاهل", () => {
  const cfg = parseConfig({ custom: [
    { id: "aaaa11", type: "text", label: "نص", required: true, step: 1 },
    { id: "bbbb22", type: "choice", label: "خيار", options: ["أ", "ب"], step: 2 },
    { id: "cccc33", type: "yesno", label: "نعم لا", step: 3 },
    { id: "dddd44", type: "long", label: "طويل", step: 5, active: false, required: true },
  ] });
  assert.equal(activeCustom(cfg).length, 3);
  const bad = validateCustomAnswers(cfg, (k) => ({ [customField("bbbb22")]: "ج", [customField("cccc33")]: "ربما" } as Record<string, string>)[k] ?? "");
  assert.deepEqual(Object.keys(bad.errors).sort(), ["cq_aaaa11", "cq_bbbb22", "cq_cccc33"]);
  const good = validateCustomAnswers(cfg, (k) => ({ cq_aaaa11: " مرحبا ", cq_bbbb22: "ب" } as Record<string, string>)[k] ?? "");
  assert.deepEqual(good.errors, {});
  assert.deepEqual(good.answers, [{ id: "aaaa11", label: "نص", value: "مرحبا" }, { id: "bbbb22", label: "خيار", value: "ب" }]);
  assert.ok(validateCustomAnswers(cfg, (k) => (k === "cq_aaaa11" ? "ن".repeat(301) : "")).errors.cq_aaaa11);
});
