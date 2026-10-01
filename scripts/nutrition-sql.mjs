// يولّد SQL استيراد قوالب التغذية والمكملات من db/seed/nutrition.json
// (مصدرها أوراق «تغذية ١–٥» و«روتين المكملات» في قالب ملف التدريب).
// آمن للتكرار: لا يضيف قالباً موجوداً بنفس الاسم، ولا يلمس نسخ المتدربين.
import { readFileSync } from "node:fs";

export function nutritionSql() {
  const seed = JSON.parse(readFileSync(new URL("../db/seed/nutrition.json", import.meta.url), "utf8"));
  const json = JSON.stringify({ plans: seed.plans, supplements: seed.supplements });
  if (json.includes("$nu$")) throw new Error("nutrition.json يحتوي $nu$");
  return `DO $do$
DECLARE
  d jsonb := $nu$${json}$nu$::jsonb;
  p jsonb; m jsonb; it jsonb; s jsonb;
  v_plan uuid; v_meal uuid; v_routine uuid; v_sec uuid;
  i int; j int; k int;
BEGIN
  i := 0;
  FOR p IN SELECT * FROM jsonb_array_elements(d->'plans') LOOP
    IF NOT EXISTS (SELECT 1 FROM nutrition_plans WHERE order_id IS NULL AND lower(trim(name)) = lower(trim(p->>'name'))) THEN
      INSERT INTO nutrition_plans (name, position) VALUES (p->>'name', i) RETURNING id INTO v_plan;
      j := 0;
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
    END IF;
    i := i + 1;
  END LOOP;

  s := d->'supplements';
  IF NOT EXISTS (SELECT 1 FROM supplement_routines WHERE order_id IS NULL AND lower(trim(name)) = lower(trim(s->>'name'))) THEN
    INSERT INTO supplement_routines (name, intro) VALUES (s->>'name', s->>'intro') RETURNING id INTO v_routine;
    j := 0;
    FOR m IN SELECT * FROM jsonb_array_elements(s->'sections') LOOP
      INSERT INTO supplement_sections (routine_id, title, routine, position) VALUES (v_routine, m->>'title', nullif(m->>'routine', ''), j) RETURNING id INTO v_sec;
      k := 0;
      FOR it IN SELECT * FROM jsonb_array_elements(m->'items') LOOP
        INSERT INTO supplement_items (section_id, name, dose, timing, importance, benefit, link, position)
        VALUES (v_sec, it->>'name', it->>'dose', it->>'timing', it->>'importance', it->>'benefit', it->>'link', k);
        k := k + 1;
      END LOOP;
      j := j + 1;
    END LOOP;
  END IF;
END $do$;
`;
}
