// يولّد قوالب الجداول الغذائية اليومية (فطور، غداء، عشاء، سناك) من وصفات كتيب الوصفات (db/seed/recipes.json).
// الأرقام (بروتين/كارب/دهون) كما في الكتيب حرفياً؛ السعرات تحسبها الصفحة = بروتين×4 + كارب×4 + دهون×9.
// الاختيار آلي بقاعدة واضحة لكل قالب (نفس الوصفة ما تتكرر في اليوم).
// آمن للتكرار: القالب الموجود بنفس الاسم تُستبدل وجباته بالنسخة الحالية (نسخ المتدربين المُسندة ما تتأثر).
import { readFileSync } from "node:fs";
import { foodDetailsSql } from "./foods-sql.mjs";

const KIND = { b: "breakfast", l: "lunch", s: "snack" };
export const kcalOf = (r) => 4 * r.protein + 4 * r.carbs + 9 * r.fat;

export function loadRecipes() {
  return JSON.parse(readFileSync(new URL("../db/seed/recipes.json", import.meta.url), "utf8"));
}

/** فطور واحد + غداء + عشاء + سناك، يُختاران بمفتاح ترتيب (الأصغر أولاً؛ التعادل بالسعرات ثم الاسم) */
function pick(recipes, key) {
  const by = (slot) => recipes.filter((r) => r.slot === slot && !r.set).sort((a, b) => key(a) - key(b) || kcalOf(a) - kcalOf(b) || a.id.localeCompare(b.id));
  const [b] = by("b"), [l1, l2] = by("l"), [s] = by("s");
  return { b, l1, l2, s };
}

export const TEMPLATES = [
  { name: "قالب منخفض السعرات", rule: "أقل سعرات ممكنة من وصفات الكتيب", key: (r) => kcalOf(r) },
  { name: "قالب عالي السعرات", rule: "أعلى سعرات ممكنة من وصفات الكتيب", key: (r) => -kcalOf(r) },
  { name: "قالب عالي البروتين", rule: "أعلى بروتين ممكن من وصفات الكتيب", key: (r) => -r.protein },
  { name: "قالب عالي الكارب", rule: "أعلى كارب ممكن من وصفات الكتيب", key: (r) => -r.carbs },
  { name: "قالب قليل الكارب", rule: "أقل كارب ممكن من وصفات الكتيب", key: (r) => r.carbs },
];

const mealOf = (kind, r) => ({
  kind, title: r.name,
  method: `المكونات:\n${r.ingredients.map((i) => `• ${i}`).join("\n")}\n\nالطريقة:\n${r.steps.map((s, i) => `${i + 1}. ${s}`).join("\n")}${r.fiber != null ? `\n\nالألياف: ${r.fiber}غ` : ""}${r.note ? `\n\nملاحظة: ${r.note}` : ""}`,
  items: [{ food: r.name, portion: r.portion, protein: r.protein, carbs: r.carbs, fat: r.fat }],
});

// قالب مضادات الأكسدة: وصفات محددة بالاسم (مكوناتها توت، رمان، سبانخ، طماطم، فلفل أحمر، شوكولاتة داكنة...)
export const ANTIOXIDANT = { name: "قالب مضادات الأكسدة", ids: ["ao-shakshuka", "ao-salmon-quinoa", "ao-lentil-salad", "ao-berries-dark"],
  rule: "وصفات غنية بمصادر مضادات الأكسدة (توت، رمان، سبانخ، طماطم، فلفل أحمر، شوكولاتة داكنة، مكسرات، زيت زيتون)" };

// قالب عالي الألياف: وصفات فيها 8غ ألياف أو أكثر للوجبة الرئيسية (الاحتياج اليومي 28غ)، والألياف محسوبة من قاعدة الأكل
export const FIBER = { name: "قالب عالي الألياف", ids: ["f-oats-chia", "f-chili", "f-salmon-lentil", "f-dates-almonds"],
  rule: "وجبات عالية بالألياف (بقوليات، شوفان، حبوب كاملة، خضار وفواكه ومكسرات). زيدي الألياف تدريجياً مع شرب ماء كافي" };
// مكتبة الوجبات: كل الوصفات (الكتيب + مضادات الأكسدة + الإضافية + الألياف) كوجبات لاختيار المتدرب من «كل الوجبات»
export const LIBRARY = { name: "مكتبة الوجبات", library: true, all: true,
  rule: "كل الوصفات كوجبات منفردة (فطور وغداء وسناك) ليختار منها المتدرب في «كل الوجبات». مو جدول يومي، فلا تُسند لمتدرب" };
const GROUPS = { main: TEMPLATES, antioxidant: [ANTIOXIDANT], fiber: [FIBER], library: [LIBRARY] };

export function buildPlans(recipes = loadRecipes(), group = "main") {
  const defs = GROUPS[group] ?? TEMPLATES;
  return defs.map((t) => {
    let b, l1, l2, s;
    if (t.all) {
      const kind = { b: "breakfast", l: "lunch", s: "snack" };
      const meals = recipes.map((r) => mealOf(kind[r.slot], r));
      return { name: t.name, notes: `${t.rule}. ${meals.length} وجبة.`, meals, library: true, kcal: 0, fiber: null, protein: 0, carbs: 0, fat: 0 };
    }
    if (t.ids) {
      const get = (id) => recipes.find((r) => r.id === id);
      [b, l1, l2, s] = t.ids.map(get);
    } else ({ b, l1, l2, s } = pick(recipes, t.key));
    const meals = [mealOf("breakfast", b), mealOf("lunch", l1), mealOf("dinner", l2), mealOf("snack", s)];
    const all = [b, l1, l2, s];
    const tot = { protein: 0, carbs: 0, fat: 0 };
    for (const r of all) { tot.protein += r.protein; tot.carbs += r.carbs; tot.fat += r.fat; }
    const fiber = all.every((r) => r.fiber != null) ? Math.round(all.reduce((a, r) => a + r.fiber, 0)) : null;
    const kcal = Math.round(4 * tot.protein + 4 * tot.carbs + 9 * tot.fat);
    const notes = `${t.rule}. ${t.ids ? "الأرقام محسوبة من مكونات كل وصفة بقاعدة بيانات USDA." : "مكوّن من وصفات كتيب الوصفات: فطور، غداء، عشاء، سناك. الأرقام كما في الكتيب."} المجموع تقريباً ${kcal} سعرة (بروتين ${Math.round(tot.protein)}غ، كارب ${Math.round(tot.carbs)}غ، دهون ${Math.round(tot.fat)}غ${fiber != null ? `، ألياف ${fiber}غ` : ""}).`;
    return { name: t.name, notes, meals, kcal, fiber, ...tot };
  });
}

export function recipeTemplatesSql(group = "main") {
  const plans = buildPlans(loadRecipes(), group);
  const json = JSON.stringify(plans.map(({ name, notes, meals, library }) => ({ name, notes, meals, ...(library ? { library: true } : {}) })));
  if (json.includes("$rt$")) throw new Error("recipes.json يحتوي $rt$");
  return `DO $do$
DECLARE
  d jsonb := $rt$${json}$rt$::jsonb;
  p jsonb; m jsonb; it jsonb;
  v_plan uuid; v_meal uuid; i int; j int; k int;
BEGIN
  i := 100 + (SELECT count(*) FROM nutrition_plans WHERE order_id IS NULL);
  FOR p IN SELECT * FROM jsonb_array_elements(d) LOOP
    SELECT id INTO v_plan FROM nutrition_plans WHERE order_id IS NULL AND lower(trim(name)) = lower(trim(p->>'name'));
    IF v_plan IS NULL THEN
      ${group === "library"
        ? `INSERT INTO nutrition_plans (name, notes, position, is_library) VALUES (p->>'name', p->>'notes', 1000, true) RETURNING id INTO v_plan;`
        : `INSERT INTO nutrition_plans (name, notes, position) VALUES (p->>'name', p->>'notes', i) RETURNING id INTO v_plan;`}
    ELSE
      -- تحديث: الوجبات تُستبدل بالنسخة الحالية (الحذف يشمل عناصرها)
      DELETE FROM plan_meals WHERE plan_id = v_plan;
      UPDATE nutrition_plans SET notes = p->>'notes', updated_at = now() WHERE id = v_plan;
    END IF;
    i := i + 1; j := 0;
    FOR m IN SELECT * FROM jsonb_array_elements(p->'meals') LOOP
      INSERT INTO plan_meals (plan_id, kind, title, method, position) VALUES (v_plan, m->>'kind', m->>'title', nullif(m->>'method', ''), j) RETURNING id INTO v_meal;
      k := 0;
      FOR it IN SELECT * FROM jsonb_array_elements(m->'items') LOOP
        INSERT INTO plan_items (meal_id, food, portion, protein, carbs, fat, position)
        VALUES (v_meal, it->>'food', nullif(it->>'portion', ''), (it->>'protein')::numeric, (it->>'carbs')::numeric, (it->>'fat')::numeric, k);
        k := k + 1;
      END LOOP;
      j := j + 1;
    END LOOP;
  END LOOP;
END $do$;
`;
}

/** جُمل migration كنص (بدون التعليقات)، كل جملة لوحدها لتُنفَّذ داخل كتلة شرطية */
function migrationStatements(file) {
  return readFileSync(new URL(`../db/migrations/${file}`, import.meta.url), "utf8")
    .split("\n").filter((l) => !l.trim().startsWith("--")).join("\n")
    .split(";").map((x) => x.trim()).filter(Boolean);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const group = ["antioxidant", "fiber", "library"].includes(process.argv[2]) ? process.argv[2] : "main";
  const head = group === "library"
    ? `-- مكتبة الوجبات: كل الوصفات كوجبات يختار منها المتدرب في «كل الوجبات» + migration 030 (عمود is_library وتسمية سجل الأكل).
-- يُشغَّل في Neon ← SQL Editor في محرر فاضي، بعد ملف library-meals (029). تُضاف المكتبة مرة، وتُحدَّث لو انشغّل مرتين.`
    : group === "fiber"
    ? `-- قالب عالي الألياف (فطور، غداء، عشاء، سناك) + تفاصيل مصادر الأكل (نوع المصدر، الألياف، الفيتامينات والمعادن من USDA).
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف antioxidant-template. تفاصيل الأكل تُضاف مرة وحدة، والقالب يُحدَّث لو انشغّل مرتين.`
    : group === "antioxidant"
    ? `-- قالب مضادات الأكسدة: فطور وغداء وعشاء وسناك من وصفات غنية بمصادر مضادات الأكسدة (الأرقام محسوبة من قاعدة الأكل).
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف recipe-templates. يضيف القالب، أو يحدّث وجباته إذا كان موجوداً (نسخ المتدربين ما تتأثر). آمن لو انشغّل مرتين.`
    : `-- قوالب جداول غذائية يومية من كتيب الوصفات: منخفض/عالي السعرات، عالي البروتين، عالي الكارب، قليل الكارب. كل قالب: فطور وغداء وعشاء وسناك.
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف auto-kcal-hidden. يضيف القوالب، أو يحدّث وجباتها إذا كانت موجودة (نسخ المتدربين ما تتأثر). آمن لو انشغّل مرتين.`;
  const names = buildPlans(loadRecipes(), group).map((p) => p.name.replace(/'/g, "''"));
  // ملف الألياف يحمل معه migration 028 (أعمدة التفاصيل) وتعبئتها من USDA، مرة وحدة
  const details = group === "library" ? `DO $g$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '030_meal_library_plan.sql') THEN
    EXECUTE $mig$${readFileSync(new URL("../db/migrations/030_meal_library_plan.sql", import.meta.url), "utf8")}$mig$;
    INSERT INTO schema_migrations (name) VALUES ('030_meal_library_plan.sql');
  END IF;
END $g$;
` : group !== "fiber" ? "" : `DO $g$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE name = '028_food_details.sql') THEN
${migrationStatements("028_food_details.sql").map((st) => `    EXECUTE $m$${st}$m$;`).join("\n")}
    INSERT INTO schema_migrations (name) VALUES ('028_food_details.sql');
  END IF;
END $g$;
${foodDetailsSql()}`;
  const out = `${head}
BEGIN;
${details}${recipeTemplatesSql(group)}
SELECT p.name, round(sum(i.protein*4 + i.carbs*4 + i.fat*9)) AS kcal, count(DISTINCT m.id) AS meals
  FROM nutrition_plans p JOIN plan_meals m ON m.plan_id = p.id JOIN plan_items i ON i.meal_id = m.id
 WHERE p.order_id IS NULL AND p.name IN (${names.map((n) => `'${n}'`).join(", ")}) GROUP BY p.name, p.position ORDER BY p.position;
COMMIT;
`;
  process.stdout.write(out);
}
