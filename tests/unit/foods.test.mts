// الأكل بالغرامات: التحويل من قيم 100غ، وتحويل حصص FatSecret المترية إلى 100غ.
import { test } from "node:test";
import assert from "node:assert/strict";
import { scaleFood } from "../../src/lib/nutrition.ts";
import { per100FromServings } from "../../src/lib/fatsecret.ts";

test("الكمية بالغرام = قيم 100غ × الغرامات ÷ 100", () => {
  const f = { protein_100: 2.7, carbs_100: 28.2, fat_100: 0.3 };
  assert.deepEqual(scaleFood(f, 100), { protein: 2.7, carbs: 28.2, fat: 0.3, kcal: 126 });
  assert.deepEqual(scaleFood(f, 150), { protein: 4.1, carbs: 42.3, fat: 0.5, kcal: 190 });
});
test("FatSecret: الحصة المترية الافتراضية تُحوَّل لكل 100غ، والحصص غير المترية تُتجاهل", () => {
  const p = per100FromServings([
    { metric_serving_amount: "", metric_serving_unit: "", protein: "10", carbohydrate: "1", fat: "1" },
    { metric_serving_amount: "50.000", metric_serving_unit: "g", protein: "3.0", carbohydrate: "10", fat: "1.5", calories: "65", is_default: "1" },
  ]);
  assert.deepEqual(p, { protein_100: 6, carbs_100: 20, fat_100: 3, kcal_100: 130, serving_g: 50 });
  assert.equal(per100FromServings([{ metric_serving_amount: "1", metric_serving_unit: "oz", protein: "1" }]), null);
});
