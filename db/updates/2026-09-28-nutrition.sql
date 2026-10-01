-- المرحلة الثانية: التغذية (الأهداف، الجداول الغذائية، سجل الأكل) وروتين المكملات + استيراد القوالب من ملف التدريب.
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف exercise-taxonomy. لا يغيّر أي بيانات موجودة.
BEGIN;
-- =====================================================================
-- التغذية والمكملات (بديل أوراق «التعليمات» و«تغذية ١–٥» و«Macro Log» و«روتين المكملات»).
-- * الجداول الغذائية وروتين المكملات: order_id فارغ = قالب في مكتبة المدربة، وغير فارغ = نسخة لمتدرب.
--   الإسناد ينسخ القالب للمتدرب، فتعديله لا يغيّر القالب ولا العكس.
-- * المتدرب يقرأ نسخه فقط بعد تأكيد الدفع (app.order_entitled)، والكتابة للمدربة فقط.
-- * سجل الأكل اليومي يكتبه المتدرب عبر دوال فقط: من وجبات جداوله أو إدخال حر.
-- =====================================================================

-- ---------- الأهداف اليومية لكل متدرب ----------
CREATE TABLE nutrition_targets (
  order_id uuid PRIMARY KEY REFERENCES orders (id) ON DELETE CASCADE,
  kcal int CHECK (kcal IS NULL OR kcal BETWEEN 500 and 10000),
  protein numeric(6,1) CHECK (protein IS NULL OR protein BETWEEN 0 AND 1000),
  carbs numeric(6,1) CHECK (carbs IS NULL OR carbs BETWEEN 0 AND 1500),
  fat numeric(6,1) CHECK (fat IS NULL OR fat BETWEEN 0 AND 500),
  rules text CHECK (rules IS NULL OR length(rules) <= 5000),
  updated_by text REFERENCES "user" (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- الجداول الغذائية (قوالب ونسخ المتدربين) ----------
CREATE TABLE nutrition_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES orders (id) ON DELETE CASCADE,          -- فارغ = قالب
  source_id uuid REFERENCES nutrition_plans (id) ON DELETE SET NULL,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  notes text CHECK (notes IS NULL OR length(notes) <= 3000),
  position int NOT NULL DEFAULT 0,
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX nutrition_plans_order_idx ON nutrition_plans (order_id, position);
CREATE UNIQUE INDEX nutrition_plans_template_name ON nutrition_plans (lower(trim(name))) WHERE order_id IS NULL;

CREATE TABLE plan_meals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES nutrition_plans (id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('breakfast', 'lunch', 'dinner', 'snack')),
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 120),
  method text CHECK (method IS NULL OR length(method) <= 3000),     -- طريقة التحضير
  position int NOT NULL DEFAULT 0
);
CREATE INDEX plan_meals_plan_idx ON plan_meals (plan_id, position);

CREATE TABLE plan_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meal_id uuid NOT NULL REFERENCES plan_meals (id) ON DELETE CASCADE,
  food text NOT NULL CHECK (length(trim(food)) BETWEEN 1 AND 160),
  portion text CHECK (portion IS NULL OR length(portion) <= 80),
  protein numeric(6,1) NOT NULL DEFAULT 0 CHECK (protein BETWEEN 0 AND 500),
  carbs numeric(6,1) NOT NULL DEFAULT 0 CHECK (carbs BETWEEN 0 AND 500),
  fat numeric(6,1) NOT NULL DEFAULT 0 CHECK (fat BETWEEN 0 AND 300),
  position int NOT NULL DEFAULT 0
);
CREATE INDEX plan_items_meal_idx ON plan_items (meal_id, position);

-- ---------- سجل الأكل اليومي (Macro Log) ----------
CREATE TABLE food_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text NOT NULL REFERENCES "user" (id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  log_date date NOT NULL,
  kind text NOT NULL CHECK (kind IN ('breakfast', 'lunch', 'dinner', 'snack')),
  meal_id uuid REFERENCES plan_meals (id) ON DELETE SET NULL,       -- فارغ = إدخال حر
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  protein numeric(6,1) NOT NULL CHECK (protein BETWEEN 0 AND 500),
  carbs numeric(6,1) NOT NULL CHECK (carbs BETWEEN 0 AND 500),
  fat numeric(6,1) NOT NULL CHECK (fat BETWEEN 0 AND 300),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX food_logs_user_date_idx ON food_logs (user_id, log_date DESC);
CREATE INDEX food_logs_order_date_idx ON food_logs (order_id, log_date DESC);

-- ---------- روتين المكملات (قوالب ونسخ المتدربين) ----------
CREATE TABLE supplement_routines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES orders (id) ON DELETE CASCADE,          -- فارغ = قالب
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  intro text CHECK (intro IS NULL OR length(intro) <= 2000),
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX supplement_routines_one_per_order ON supplement_routines (order_id) WHERE order_id IS NOT NULL;
CREATE UNIQUE INDEX supplement_routines_template_name ON supplement_routines (lower(trim(name))) WHERE order_id IS NULL;

CREATE TABLE supplement_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  routine_id uuid NOT NULL REFERENCES supplement_routines (id) ON DELETE CASCADE,
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 120),
  routine text CHECK (routine IS NULL OR length(routine) <= 4000),   -- نص «الروتين» تحت القسم
  position int NOT NULL DEFAULT 0
);
CREATE TABLE supplement_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id uuid NOT NULL REFERENCES supplement_sections (id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  dose text CHECK (dose IS NULL OR length(dose) <= 120),
  timing text CHECK (timing IS NULL OR length(timing) <= 160),
  importance text CHECK (importance IS NULL OR length(importance) <= 60),
  benefit text CHECK (benefit IS NULL OR length(benefit) <= 1000),
  link text CHECK (link IS NULL OR link ~ '^https://'),
  position int NOT NULL DEFAULT 0
);

-- ---------- صلاحيات ----------
CREATE OR REPLACE FUNCTION app.plan_visible(p_plan uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.id = p_plan AND p.order_id IS NOT NULL AND NOT p.archived AND app.order_entitled(p.order_id))
$$;
CREATE OR REPLACE FUNCTION app.meal_plan(p_meal uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT plan_id FROM plan_meals WHERE id = p_meal $$;
CREATE OR REPLACE FUNCTION app.routine_visible(p_routine uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.id = p_routine AND r.order_id IS NOT NULL AND NOT r.archived AND app.order_entitled(r.order_id))
$$;
CREATE OR REPLACE FUNCTION app.section_routine(p_section uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT routine_id FROM supplement_sections WHERE id = p_section $$;

ALTER TABLE nutrition_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE nutrition_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_meals ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE food_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_routines ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY targets_read ON nutrition_targets FOR SELECT USING (app.is_coach() OR app.order_entitled(order_id));
CREATE POLICY targets_write ON nutrition_targets FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY nplans_read ON nutrition_plans FOR SELECT USING (app.plan_visible(id));
CREATE POLICY nplans_write ON nutrition_plans FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY pmeals_read ON plan_meals FOR SELECT USING (app.plan_visible(plan_id));
CREATE POLICY pmeals_write ON plan_meals FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY pitems_read ON plan_items FOR SELECT USING (app.plan_visible(app.meal_plan(meal_id)));
CREATE POLICY pitems_write ON plan_items FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY food_logs_read ON food_logs FOR SELECT USING (user_id = app.uid() OR app.is_coach());
CREATE POLICY sroutines_read ON supplement_routines FOR SELECT USING (app.routine_visible(id));
CREATE POLICY sroutines_write ON supplement_routines FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY ssections_read ON supplement_sections FOR SELECT USING (app.routine_visible(routine_id));
CREATE POLICY ssections_write ON supplement_sections FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
CREATE POLICY sitems_read ON supplement_items FOR SELECT USING (app.routine_visible(app.section_routine(section_id)));
CREATE POLICY sitems_write ON supplement_items FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());

GRANT SELECT, INSERT, UPDATE, DELETE ON nutrition_targets, nutrition_plans, plan_meals, plan_items,
  supplement_routines, supplement_sections, supplement_items TO nav_app;
GRANT SELECT ON food_logs TO nav_app;

-- ---------- المتدرب: سجل الأكل ----------
-- إضافة: من وجبة في جداوله (p_meal) بمجموع مكوناتها، أو إدخال حر (الاسم والماكروز)
CREATE OR REPLACE FUNCTION app.log_food(p_order_no text, p_date date, p_kind text, p_meal uuid,
                                        p_name text, p_protein numeric, p_carbs numeric, p_fat numeric) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  u text := app.require_user();
  v_order uuid;
  today date := (now() AT TIME ZONE 'Asia/Riyadh')::date;
  v_name text; v_p numeric; v_c numeric; v_f numeric; v_kind text := p_kind;
  v_id bigint;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no AND user_id = u;
  IF NOT FOUND OR NOT app.order_entitled(v_order) THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_date IS NULL OR p_date > today OR p_date < today - 60 THEN RAISE EXCEPTION 'التاريخ غير صحيح.' USING ERRCODE = 'P0001'; END IF;
  IF p_meal IS NOT NULL THEN
    SELECT m.title, m.kind, coalesce(sum(i.protein), 0), coalesce(sum(i.carbs), 0), coalesce(sum(i.fat), 0)
      INTO v_name, v_kind, v_p, v_c, v_f
      FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id LEFT JOIN plan_items i ON i.meal_id = m.id
     WHERE m.id = p_meal AND p.order_id = v_order AND NOT p.archived
     GROUP BY m.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'الوجبة غير موجودة في جداولك.' USING ERRCODE = 'P0001'; END IF;
    v_name := (SELECT name FROM nutrition_plans WHERE id = app.meal_plan(p_meal)) || ' — ' || v_name;
    v_kind := coalesce(p_kind, v_kind);
  ELSE
    v_name := nullif(trim(coalesce(p_name, '')), '');
    IF v_name IS NULL THEN RAISE EXCEPTION 'اكتب اسم الأكلة.' USING ERRCODE = 'P0001'; END IF;
    v_p := coalesce(p_protein, 0); v_c := coalesce(p_carbs, 0); v_f := coalesce(p_fat, 0);
    IF v_p < 0 OR v_c < 0 OR v_f < 0 OR v_p > 500 OR v_c > 500 OR v_f > 300 THEN
      RAISE EXCEPTION 'أرقام الماكروز غير منطقية.' USING ERRCODE = 'P0001';
    END IF;
    IF v_p + v_c + v_f = 0 THEN RAISE EXCEPTION 'اكتب البروتين أو الكارب أو الدهون.' USING ERRCODE = 'P0001'; END IF;
  END IF;
  IF v_kind NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN RAISE EXCEPTION 'اختر الوجبة.' USING ERRCODE = 'P0001'; END IF;
  IF (SELECT count(*) FROM food_logs WHERE user_id = u AND log_date = p_date) >= 30 THEN
    RAISE EXCEPTION 'وصلت الحد الأعلى لتسجيلات اليوم.' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO food_logs (user_id, order_id, log_date, kind, meal_id, name, protein, carbs, fat)
  VALUES (u, v_order, p_date, v_kind, p_meal, left(v_name, 160), round(v_p, 1), round(v_c, 1), round(v_f, 1))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app.delete_food_log(p_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u text := app.require_user();
BEGIN
  DELETE FROM food_logs WHERE id = p_id AND user_id = u AND log_date >= (now() AT TIME ZONE 'Asia/Riyadh')::date - 60;
  IF NOT FOUND THEN RAISE EXCEPTION 'التسجيل غير موجود.' USING ERRCODE = 'P0001'; END IF;
END $$;

-- ---------- المدربة: إسناد قالب (نسخ) ----------
CREATE OR REPLACE FUNCTION app.coach_assign_nutrition(p_order_no text, p_template uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid; v_tpl nutrition_plans%ROWTYPE; v_new uuid; m record; v_meal uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_tpl FROM nutrition_plans WHERE id = p_template AND order_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'الجدول غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO nutrition_plans (order_id, source_id, name, notes, position)
  VALUES (v_order, v_tpl.id, v_tpl.name, v_tpl.notes, (SELECT coalesce(max(position), -1) + 1 FROM nutrition_plans WHERE order_id = v_order))
  RETURNING id INTO v_new;
  FOR m IN SELECT * FROM plan_meals WHERE plan_id = v_tpl.id ORDER BY position LOOP
    INSERT INTO plan_meals (plan_id, kind, title, method, position) VALUES (v_new, m.kind, m.title, m.method, m.position) RETURNING id INTO v_meal;
    INSERT INTO plan_items (meal_id, food, portion, protein, carbs, fat, position)
    SELECT v_meal, food, portion, protein, carbs, fat, position FROM plan_items WHERE meal_id = m.id;
  END LOOP;
  INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'nutrition.assign', p_order_no, jsonb_build_object('plan', v_tpl.name));
  RETURN v_new;
END $$;

CREATE OR REPLACE FUNCTION app.coach_assign_supplements(p_order_no text, p_template uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid; v_tpl supplement_routines%ROWTYPE; v_new uuid; s record; v_sec uuid;
BEGIN
  SELECT id INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_tpl FROM supplement_routines WHERE id = p_template AND order_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'الروتين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  DELETE FROM supplement_routines WHERE order_id = v_order;   -- روتين واحد لكل متدرب: الإسناد الجديد يستبدله
  INSERT INTO supplement_routines (order_id, name, intro) VALUES (v_order, v_tpl.name, v_tpl.intro) RETURNING id INTO v_new;
  FOR s IN SELECT * FROM supplement_sections WHERE routine_id = v_tpl.id ORDER BY position LOOP
    INSERT INTO supplement_sections (routine_id, title, routine, position) VALUES (v_new, s.title, s.routine, s.position) RETURNING id INTO v_sec;
    INSERT INTO supplement_items (section_id, name, dose, timing, importance, benefit, link, position)
    SELECT v_sec, name, dose, timing, importance, benefit, link, position FROM supplement_items WHERE section_id = s.id;
  END LOOP;
  INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'supplements.assign', p_order_no, jsonb_build_object('routine', v_tpl.name));
  RETURN v_new;
END $$;

REVOKE ALL ON FUNCTION app.plan_visible(uuid), app.meal_plan(uuid), app.routine_visible(uuid), app.section_routine(uuid),
  app.log_food(text, date, text, uuid, text, numeric, numeric, numeric), app.delete_food_log(bigint),
  app.coach_assign_nutrition(text, uuid), app.coach_assign_supplements(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.plan_visible(uuid), app.meal_plan(uuid), app.routine_visible(uuid), app.section_routine(uuid),
  app.log_food(text, date, text, uuid, text, numeric, numeric, numeric), app.delete_food_log(bigint),
  app.coach_assign_nutrition(text, uuid), app.coach_assign_supplements(text, uuid) TO nav_app;

DO $do$
DECLARE
  d jsonb := $nu${"plans":[{"name":"الجدول الغذائي 1","meals":[{"title":"الفطور","kind":"breakfast","items":[{"food":"بيضة كاملة (حبتين)","portion":null,"protein":12.6,"carbs":0.7,"fat":9.5},{"food":"شريحتين توست نخالة","portion":null,"protein":6.6,"carbs":28.6,"fat":2.6},{"food":"شريحة جبنة","portion":null,"protein":5.5,"carbs":0,"fat":5.5}],"method":null},{"title":"الغداء — رز مع صدور دجاج مشوية","kind":"lunch","items":[{"food":"صدور دجاج بعد الطبخ","portion":"100غ","protein":30,"carbs":0,"fat":5.4},{"food":"رز مطبوخ","portion":"200غ","protein":5.4,"carbs":57,"fat":0.5}],"method":null},{"title":"العشاء — برجر دجاج","kind":"dinner","items":[{"food":"برجر دجاج","portion":"100غ","protein":20,"carbs":5,"fat":10},{"food":"خبز برجر","portion":"75غ","protein":5.1,"carbs":28,"fat":2},{"food":"مايونيز","portion":"15غ","protein":0,"carbs":0,"fat":10}],"method":null},{"title":"السناك #1","kind":"snack","items":[{"food":"بروتين ندى","portion":"عبوة","protein":28,"carbs":42,"fat":7}],"method":null},{"title":"السناك #2","kind":"snack","items":[{"food":"كاجو","portion":"30غ","protein":5,"carbs":8,"fat":14}],"method":null}]},{"name":"الجدول الغذائي 2","meals":[{"title":"الفطور","kind":"breakfast","items":[{"food":"بيضة كاملة","portion":null,"protein":6,"carbs":0,"fat":5},{"food":"2 شريحة توست نخالة","portion":null,"protein":6,"carbs":28,"fat":3},{"food":"شرائح خيار وطماطم","portion":null,"protein":0,"carbs":0,"fat":0},{"food":"2 ملعقة كبيرة لبنة قليلة الدسم","portion":"50غ","protein":6,"carbs":3,"fat":7}],"method":null},{"title":"الغداء — شورما دجاج","kind":"lunch","items":[{"food":"دجاج مشوي","portion":"100غ","protein":30,"carbs":0,"fat":5},{"food":"زيت زيتون","portion":"ملعقة صغيرة","protein":0,"carbs":0,"fat":7},{"food":"لبنة","portion":"15غ","protein":2,"carbs":0,"fat":1.5},{"food":"خبز عربي صغير","portion":"50غ","protein":4,"carbs":27,"fat":1}],"method":null},{"title":"العشاء — باستا","kind":"dinner","items":[{"food":"مكرونة بيني — قبل الطبخ","portion":"150غ","protein":18,"carbs":111,"fat":2.2},{"food":"صدور دجاج مشوية","portion":"100غ","protein":31,"carbs":0,"fat":3.5},{"food":"جبنة فيلادلفيا لايت","portion":"30غ","protein":2.3,"carbs":2.6,"fat":5},{"food":"موزاريلا لايت","portion":"15غ","protein":1,"carbs":3,"fat":0},{"food":"صوص طماطم للباستا","portion":"50غ","protein":1,"carbs":4,"fat":0},{"food":"بصل + ثوم","portion":"15غ","protein":0,"carbs":5,"fat":0}],"method":"يُتبَّل الدجاج بالملح والبابريكا وبودرة الثوم والأوريغانو، ثم يُشوى 5 دقائق لكل جهة. يُرفع الدجاج ويُحمَّس البصل في المقلاة نفسها، ثم يُضاف الثوم والصلصة وقليل من ماء سلق المكرونة ويُخلط حتى يتجانس. تُضاف جبنة الفيلادلفيا وقليل من الماء، ثم البهارات نفسها بنسبة أقل. أخيراً تُضاف الموزاريلا ويُعاد الدجاج بعد أن يبرد، ويمكن التزيين ببودرة الفلفل الأحمر والكزبرة والأوريغانو."},{"title":"السناك #1","kind":"snack","items":[{"food":"كاجو","portion":"30غ","protein":5,"carbs":8,"fat":14}],"method":null}]},{"name":"الجدول الغذائي 3","meals":[{"title":"الفطور","kind":"breakfast","items":[{"food":"2 بيضة كاملة","portion":null,"protein":13,"carbs":1,"fat":10},{"food":"حمسة خضار (بصل، فلفل أخضر، طماطم)","portion":null,"protein":1,"carbs":4,"fat":0},{"food":"شريحة جبن قليل الدسم","portion":null,"protein":5,"carbs":0,"fat":3},{"food":"ملعقة صغيرة زيت زيتون للطبخ","portion":null,"protein":0,"carbs":0,"fat":5},{"food":"شريحتين توست نخالة","portion":"100غ","protein":4,"carbs":25,"fat":2}],"method":null},{"title":"الغداء — صحن تونة مع الأرز","kind":"lunch","items":[{"food":"تونة في ماء وملح","portion":"130غ","protein":32,"carbs":0,"fat":2},{"food":"صلصة سيراتشا","portion":"15غ","protein":0,"carbs":3,"fat":0},{"food":"مايونيز لايت","portion":"15غ","protein":0,"carbs":1,"fat":3.5},{"food":"صويا صوص خفيفة","portion":"15غ","protein":2,"carbs":1,"fat":0},{"food":"رز أبيض بعد الطبخ","portion":"300غ","protein":9,"carbs":105,"fat":1.5}],"method":"تُخلط التونة مع باقي المكونات في صحن التقديم، ثم يُضاف الأرز والتونة، وأخيراً الإضافات. ويمكن إضافة الخيار أو البصل الأخضر أو البنجر المسلوق."},{"title":"العشاء — بطاطس بالدجاج","kind":"dinner","items":[{"food":"بطاطس مشوية","portion":"200غ","protein":4,"carbs":35,"fat":0},{"food":"صدور دجاج مشوية","portion":"100غ","protein":23,"carbs":0,"fat":2.5},{"food":"جبنة فيلادلفيا لايت","portion":"50غ","protein":4,"carbs":4,"fat":8},{"food":"جبنة موزاريلا لايت","portion":"20غ","protein":5,"carbs":0,"fat":3}],"method":"تُقشَّر البطاطس وتُقطَّع، ثم تُسلق 3 دقائق وتُصفّى وتُتبَّل بالملح والفلفل الأسود والبابريكا والأوريغانو، وتوضع في القلاية الهوائية على 180 درجة لمدة 18 دقيقة. وفي المقلاة تُوضع صدور الدجاج بالتتبيلة نفسها، ثم تُضاف الفيلادلفيا مع قليل من الماء حتى تصبح كالكريمة. تُوضع البطاطس في الصحن ثم الدجاج وفوقهما الموزاريلا ورشة كزبرة، ثم يُوضع الصحن في المايكرويف قليلاً حتى يذوب الجبن."},{"title":"السناك #1","kind":"snack","items":[{"food":"كاجو","portion":"30غ","protein":5,"carbs":8,"fat":14}],"method":null}]},{"name":"الجدول الغذائي 4","meals":[{"title":"الفطور","kind":"breakfast","items":[{"food":"¾ كوب زبادي يوناني قليل الدسم","portion":"150غ","protein":15,"carbs":5,"fat":0},{"food":"موزة متوسطة الحجم","portion":"120غ","protein":1,"carbs":27,"fat":0},{"food":"لوز مطحون","portion":"5غ","protein":1,"carbs":1,"fat":3},{"food":"ملعقة صغيرة عسل","portion":null,"protein":0,"carbs":8,"fat":5},{"food":"شريحتين توست نخالة","portion":null,"protein":6.6,"carbs":29,"fat":3}],"method":null},{"title":"الغداء — توست حلوم","kind":"lunch","items":[{"food":"توست نخالة","portion":"شريحتين","protein":6,"carbs":35,"fat":3},{"food":"جبنة حلّوم قليلة الدسم","portion":"100غ","protein":22,"carbs":2,"fat":17},{"food":"زيتون","portion":"حبتين","protein":0,"carbs":0,"fat":0},{"food":"طماطم صغيرة","portion":"حبة","protein":0,"carbs":3,"fat":0},{"food":"دبس رمان","portion":"9غ","protein":0,"carbs":4.5,"fat":0}],"method":null},{"title":"العشاء — نودلز صينية","kind":"dinner","items":[{"food":"صدور دجاج مشوية","portion":"100غ","protein":23,"carbs":0,"fat":2.5},{"food":"نودلز صينية","portion":"50غ","protein":6,"carbs":35,"fat":1},{"food":"صلصة صويا حلوة","portion":"8غ","protein":0,"carbs":9,"fat":0},{"food":"فلفل رومي","portion":"60غ","protein":0,"carbs":3,"fat":0},{"food":"ثوم","portion":"5غ","protein":0,"carbs":1,"fat":0},{"food":"بصل","portion":"15غ","protein":0,"carbs":0,"fat":10}],"method":"يُوضع الدجاج في المقلاة وتُضاف إليه البهارات (ملح، بودرة ثوم وبصل، فلفل أسود)، ويُترك 5 دقائق لكل جهة. ثم يُضاف البصل والفلفل الرومي والصويا والنودلز بعد سلقها، وتُرش قليل من الماء ويُضاف الثوم، وأخيراً يُرش السمسم."},{"title":"السناك #1","kind":"snack","items":[{"food":"بروتين ندى","portion":"عبوة","protein":28,"carbs":42,"fat":7}],"method":null}]},{"name":"الجدول الغذائي 5","meals":[{"title":"الفطور","kind":"breakfast","items":[{"food":"شوفان مطبوخ بالماء","portion":"نص كوب","protein":5,"carbs":27,"fat":3},{"food":"واي بروتين","portion":"سكوب","protein":25,"carbs":3,"fat":2},{"food":"لوز","portion":"5 حبات","protein":1,"carbs":1,"fat":3},{"food":"رشة قرفة","portion":null,"protein":0,"carbs":0,"fat":0},{"food":"ملعقة عسل صغيرة","portion":null,"protein":0,"carbs":8,"fat":0}],"method":null},{"title":"الغداء — سلمون مدخن","kind":"lunch","items":[{"food":"سلمون مدخن","portion":"120غ","protein":23,"carbs":0,"fat":10},{"food":"خبز ساوردو","portion":"70غ","protein":6,"carbs":34,"fat":1},{"food":"جبنة كريمية لايت","portion":"45غ","protein":3.5,"carbs":3.8,"fat":7.5},{"food":"أفوكادو","portion":"55غ","protein":1.1,"carbs":4.6,"fat":8.1},{"food":"بقدونس + شبت + ليمون","portion":null,"protein":0,"carbs":0,"fat":0}],"method":"يُقطَّع البقدونس والشبت تقطيعاً ناعماً، وتُخلط جبنة الكريم معهما، ثم يُضاف عصير الليمون وقشر الليمون. وفي صحن التقديم يوضع خبز الساوردو ثم خليط الجبنة والأفوكادو وأخيراً السلمون، ويُزيَّن بقليل من الشبت."},{"title":"العشاء — بتر تشكن","kind":"dinner","items":[{"food":"صدر دجاج مشوي","portion":"100غ","protein":23,"carbs":0,"fat":2.5},{"food":"رز مطبوخ","portion":"200غ","protein":5.4,"carbs":57,"fat":0.5},{"food":"بصل","portion":"53غ","protein":0,"carbs":5,"fat":0},{"food":"ثوم","portion":"7غ","protein":0,"carbs":2,"fat":0},{"food":"زنجبيل","portion":"1غ","protein":0,"carbs":0,"fat":0},{"food":"طماطم","portion":"140غ","protein":1,"carbs":5.5,"fat":0},{"food":"ماء","portion":"40مل","protein":0,"carbs":0,"fat":0},{"food":"كاجو نيء","portion":"12غ","protein":2,"carbs":4,"fat":5.4}],"method":"يُقطَّع الدجاج مربعات وتُضاف إليه البهارات (ملح، بابريكا، بودرة ثوم، كيجن، كاري)، ويوضع في القلاية الهوائية 7 دقائق. وللصوص: يُحمَّس البصل حتى يذبل، ثم يُضاف الثوم والزنجبيل والطماطم حتى تتسبك، ثم يُضاف الماء والكاجو ويُخلط حتى يتجانس، ثم يُوضع في المقلاة ويُضاف الدجاج مع الصوص. وللتزيين: صوص أبيض من 5غ زبادي يوناني وماء ورشة ملح."},{"title":"السناك #1","kind":"snack","items":[{"food":"بروتين ندى","portion":"عبوة","protein":28,"carbs":42,"fat":7}],"method":null}]}],"supplements":{"name":"روتين المكملات والأداء الذهني","intro":"المكملات مساندة فقط، والأساس هو النوم والتغذية والالتزام بالتمرين","sections":[{"title":"تحسين جودة النوم","items":[{"name":"مغنيسيوم سترات","dose":"حبة","timing":"قبل النوم بساعة","importance":"مهم جداً","benefit":"يساعد على الاسترخاء وتخفيف الشدود العضلية","link":"https://sa.iherb.com/pr/solgar-magnesium-citrate-60-tablets-200-mg-per-tablet/84119?rcode=DUO2805"},{"name":"ميلاتونين","dose":"حبتين","timing":"عند الحاجة فقط","importance":"لتعديل النوم فقط","benefit":"يُستخدم عند اضطراب توقيت النوم، ولا يُستخدم يومياً","link":"https://sa.iherb.com/pr/mrm-nutrition-relax-all-sleep-60-vegan-capsules/107945?rcode=DUO2805"}],"routine":"• الروتين الليلي: يُلتزم بوقت نوم واستيقاظ ثابت حتى في نهاية الأسبوع، وتُغلق الشاشات قبل النوم بساعة على الأقل، أو تُستخدم نظارات حجب الضوء الأزرق أو خاصية Night Shift.\n• البيئة: غرفة مظلمة تماماً وباردة (18–21° مئوية).\n• التغذية: يكون العشاء قبل النوم بـ 3 ساعات، غنياً بالبروتين ومنخفض الكربوهيدرات البسيطة."},{"title":"سرعة ردات الفعل","items":[{"name":"أوميغا 3","dose":"حبتين","timing":"بعد الأكل","importance":"مهم جداً","benefit":"مهم لصحة الجسم والصحة الذهنية","link":"https://sa.iherb.com/pr/california-gold-nutrition-omega-3-premium-fish-oil-240-fish-gelatin-softgels/86598?rcode=DUO2805"},{"name":"L-Theanine + كافيين","dose":"حبة","timing":"قبل الظهر","importance":"اختياري","benefit":"يزيد التركيز والانتباه","link":"https://sa.iherb.com/pr/sports-research-l-theanine-caffeine-2-in-1-formula-60-softgels/90296?rcode=DUO2805"}],"routine":"• التمارين العصبية الحسية: تُستخدم تطبيقات مثل Human Benchmark لتدريب الاستجابة البصرية.\n• ألعاب التدريب العصبي: مثل Aim Lab أو Kovaak's FPS Trainer."},{"title":"زيادة التركيز","items":[{"name":"Alpha GPC","dose":"حبتين","timing":"قبل المذاكرة أو اللعب","importance":"مُنصَح به","benefit":"يزيد التركيز","link":"https://sa.iherb.com/pr/evlution-nutrition-alpha-gpc-60-veggie-capsules-300-mg-per-capsule/115828?rcode=DUO2805"},{"name":"5-HTP","dose":"حبة","timing":"قبل الظهر","importance":"مُنصَح به","benefit":"يحسّن جودة النوم ويقلل التوتر ويحسّن المزاج. يُستخدم عند الحاجة فقط ولمدة أقصاها 6 أسابيع، ولا يُجمع مع الميلاتونين","link":"https://sa.iherb.com/pr/nutricost-5-htp-200-mg-120-capsules/139434?rcode=DUO2805"}],"routine":"• تدريب الذهن: 10 دقائق يومياً من تمارين التأمل باستخدام تطبيق مثل Headspace أو Waking Up.\n• ألعاب تدريب الدماغ: Lumosity أو Elevate أو NeuroNation لتحفيز الذاكرة والتركيز.\n• توقيت اللعب: تُؤخذ استراحة 5 دقائق مشياً بعد كل جولة، والفرق يكون ملحوظاً."},{"title":"الصلابة الذهنية","items":[{"name":"أشواجندا KSM-66","dose":"حبة","timing":"الصباح","importance":"اختياري","benefit":"تقلل الكورتيزول وتحسّن التكيّف مع التوتر، وتُستخدم لمدة لا تزيد عن 3 أشهر","link":"https://iherb.co/8Ci4veaH"},{"name":"B-Complex","dose":"حبة","timing":"مع الفطور","importance":"اختياري","benefit":"يقلل التوتر ويحسّن المزاج","link":"https://iherb.co/NTCRTqki"},{"name":"Rhodiola Rosea","dose":"حبة","timing":"الصباح على معدة فارغة","importance":"مُنصَح به","benefit":"تزيد القدرة على التحمل الذهني وتقلل الإرهاق تحت الضغط","link":"https://iherb.co/GQMVsEzH"},{"name":"بروبيوتيك","dose":"حبة","timing":"بعد الفطور","importance":"مُنصَح به","benefit":"يقلل انتفاخات القولون وآلام المعدة","link":"https://iherb.co/15efebLX"},{"name":"الكرياتين","dose":"سكوب مع ماء","timing":"قبل النادي","importance":"مهم جداً","benefit":"يزيد التركيز والبناء العضلي","link":"https://iherb.co/ThpvD9yc"}],"routine":"• بناء عادات يومية: مثل ترتيب السرير — أثره عميق في تحسين التركيز.\n• الدعم النفسي: جلسات مع مختص في الأداء الذهني أو علم النفس الرياضي.\n• روتين الاستيقاظ: يُفضَّل عدم الإمساك بالجوال في أول ساعة بعد الاستيقاظ، ويُخصَّص ما قبل النوم بساعة بعيداً عن الجوال، بقراءة كتاب أو بكتابة ما يُفتخَر به في اليوم وما يُحمَد الله عليه."}]}}$nu$::jsonb;
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

INSERT INTO schema_migrations (name) VALUES ('011_nutrition.sql');
COMMIT;
