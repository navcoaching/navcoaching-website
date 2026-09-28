// يولّد قوالب الجداول الغذائية اليومية (فطور، غداء، عشاء، سناك) من وصفات كتيب الوصفات (db/seed/recipes.json).
// الأرقام (بروتين/كارب/دهون) كما في الكتيب حرفياً؛ السعرات تحسبها الصفحة = بروتين×4 + كارب×4 + دهون×9.
// الاختيار آلي بقاعدة واضحة لكل قالب (نفس الوصفة ما تتكرر في اليوم)، وآمن للتكرار: لا يضيف قالباً موجوداً بنفس الاسم.
import { readFileSync } from "node:fs";

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
  method: `المكونات:\n${r.ingredients.map((i) => `• ${i}`).join("\n")}\n\nالطريقة:\n${r.steps.map((s, i) => `${i + 1}. ${s}`).join("\n")}${r.note ? `\n\nملاحظة: ${r.note}` : ""}`,
  items: [{ food: r.name, portion: r.portion, protein: r.protein, carbs: r.carbs, fat: r.fat }],
});

// قالب مضادات الأكسدة: وصفات محددة بالاسم (مكوناتها توت، رمان، سبانخ، طماطم، فلفل أحمر، شوكولاتة داكنة...)
export const ANTIOXIDANT = { name: "قالب مضادات الأكسدة", ids: ["ao-shakshuka", "ao-salmon-quinoa", "ao-lentil-salad", "ao-berries-dark"],
  rule: "وصفات غنية بمصادر مضادات الأكسدة (توت، رمان، سبانخ، طماطم، فلفل أحمر، شوكولاتة داكنة، مكسرات، زيت زيتون)" };

export function buildPlans(recipes = loadRecipes(), group = "main") {
  const defs = group === "antioxidant" ? [ANTIOXIDANT] : TEMPLATES;
  return defs.map((t) => {
    let b, l1, l2, s;
    if (t.ids) {
      const get = (id) => recipes.find((r) => r.id === id);
      [b, l1, l2, s] = t.ids.map(get);
    } else ({ b, l1, l2, s } = pick(recipes, t.key));
    const meals = [mealOf("breakfast", b), mealOf("lunch", l1), mealOf("dinner", l2), mealOf("snack", s)];
    const all = [b, l1, l2, s];
    const tot = { protein: 0, carbs: 0, fat: 0 };
    for (const r of all) { tot.protein += r.protein; tot.carbs += r.carbs; tot.fat += r.fat; }
    const kcal = Math.round(4 * tot.protein + 4 * tot.carbs + 9 * tot.fat);
    const notes = `${t.rule}. ${t.ids ? "الأرقام محسوبة من مكونات كل وصفة بقاعدة بيانات USDA." : "مكوّن من وصفات كتيب الوصفات: فطور، غداء، عشاء، سناك. الأرقام كما في الكتيب."} المجموع تقريباً ${kcal} سعرة (بروتين ${Math.round(tot.protein)}غ، كارب ${Math.round(tot.carbs)}غ، دهون ${Math.round(tot.fat)}غ).`;
    return { name: t.name, notes, meals, kcal, ...tot };
  });
}

export function recipeTemplatesSql(group = "main") {
  const plans = buildPlans(loadRecipes(), group);
  const json = JSON.stringify(plans.map(({ name, notes, meals }) => ({ name, notes, meals })));
  if (json.includes("$rt$")) throw new Error("recipes.json يحتوي $rt$");
  return `DO $do$
DECLARE
  d jsonb := $rt$${json}$rt$::jsonb;
  p jsonb; m jsonb; it jsonb;
  v_plan uuid; v_meal uuid; i int; j int; k int;
BEGIN
  IF EXISTS (SELECT 1 FROM nutrition_plans WHERE order_id IS NULL AND lower(trim(name)) IN (SELECT lower(trim(x->>'name')) FROM jsonb_array_elements(d) x)) THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل (القوالب موجودة). لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
  i := 100 + (SELECT count(*) FROM nutrition_plans WHERE order_id IS NULL);
  FOR p IN SELECT * FROM jsonb_array_elements(d) LOOP
    INSERT INTO nutrition_plans (name, notes, position) VALUES (p->>'name', p->>'notes', i) RETURNING id INTO v_plan;
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

if (import.meta.url === `file://${process.argv[1]}`) {
  const group = process.argv[2] === "antioxidant" ? "antioxidant" : "main";
  const head = group === "antioxidant"
    ? `-- قالب مضادات الأكسدة: فطور وغداء وعشاء وسناك من وصفات غنية بمصادر مضادات الأكسدة (الأرقام محسوبة من قاعدة الأكل).
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف recipe-templates. يضيف قالباً جديداً فقط، ولا يغيّر شيئاً موجوداً.`
    : `-- قوالب جداول غذائية يومية من كتيب الوصفات: منخفض/عالي السعرات، عالي البروتين، عالي الكارب، قليل الكارب. كل قالب: فطور وغداء وعشاء وسناك.
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف auto-kcal-hidden. يضيف قوالب جديدة فقط، ولا يغيّر شيئاً موجوداً.`;
  const names = buildPlans(loadRecipes(), group).map((p) => p.name.replace(/'/g, "''"));
  const out = `${head}
BEGIN;
${recipeTemplatesSql(group)}
SELECT p.name, round(sum(i.protein*4 + i.carbs*4 + i.fat*9)) AS kcal, count(DISTINCT m.id) AS meals
  FROM nutrition_plans p JOIN plan_meals m ON m.plan_id = p.id JOIN plan_items i ON i.meal_id = m.id
 WHERE p.order_id IS NULL AND p.name IN (${names.map((n) => `'${n}'`).join(", ")}) GROUP BY p.name, p.position ORDER BY p.position;
COMMIT;
`;
  process.stdout.write(out);
}
