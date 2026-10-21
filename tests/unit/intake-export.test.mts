import { test } from "node:test";
import assert from "node:assert/strict";
import { intakeMarkdown } from "../../src/lib/intake-export.ts";

test("تصدير الاستبيان: Markdown مرتب بدون الجوال والبريد", () => {
  const md = intakeMarkdown(
    { order_no: "NAV-261020-UZ5YM", product_name: "الباقة المكثفة", offer_label: "3 أشهر", user_name: "حساب", contact_name: "سارة", student_discount_requested: true, client_note: null },
    {
      answers: { expectations: "متابعة\nقريبة", age: 28, goal: "نزول دهون", equip: ["دمبلز", "بنش"], notes: "سطر أول\nسطر ثاني", custom: [{ id: "c1", label: "سؤال مخصص", value: "جواب" }] },
      health: { weight: 70, height: 165, injury: "نعم", health_notes: "ركبة" },
      health_flag: true, media_consent: "لا، أفضّل الخصوصية", created_at: "2026-10-20T10:00:00Z",
    },
  );
  assert.match(md, /^# استبيان المتدرب: NAV-261020-UZ5YM/);
  assert.match(md, /- \*\*الاسم:\*\* سارة/);
  assert.match(md, /- \*\*الباقة:\*\* الباقة المكثفة · 3 أشهر/);
  assert.match(md, /- \*\*تاريخ الاستبيان:\*\* 2026-10-20/);
  assert.match(md, /> متابعة\n> قريبة/);
  assert.match(md, /- \*\*العمر:\*\* 28 سنة/);
  assert.match(md, /- \*\*الوزن \(كغ\):\*\* 70/);
  assert.match(md, /- \*\*الأدوات:\*\* دمبلز، بنش/);
  assert.match(md, /- \*\*إضافات:\*\* سطر أول \/ سطر ثاني/);
  assert.match(md, /- \*\*سؤال مخصص:\*\* جواب/);
  assert.match(md, /## البيانات الصحية \(سرية\) — تحتاج مراعاة/);
  assert.match(md, /- \*\*إصابة حالية:\*\* نعم/);
  assert.match(md, /- \*\*طلب خصم طالب:\*\* نعم/);
  assert.match(md, /- \*\*ملاحظة العميل:\*\* —/);
  // الوزن والطول مرة واحدة (في الأساسيات) ولا يتكرر حقل custom أو expectations كسطر خام
  assert.equal(md.match(/الوزن \(كغ\)/g)?.length, 1);
  assert.doesNotMatch(md, /custom|expectations|\+966|@/);
});

test("تصدير الاستبيان: الأقسام الفارغة تظهر «—»", () => {
  const md = intakeMarkdown({ order_no: "NAV-1", product_name: "باقة" }, { answers: {}, health: {}, health_flag: false, media_consent: "نعم", created_at: "2026-10-20T10:00:00Z" });
  assert.match(md, /## الإجابات\n\n- —\n/);
  assert.match(md, /## البيانات الصحية \(سرية\)\n\n- —\n/);
});
