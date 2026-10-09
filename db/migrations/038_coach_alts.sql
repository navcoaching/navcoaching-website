-- =====================================================================
-- «ناف برو» في تطبيق الجوال: اشتراك واحد يجمع
--  * بدائل الكوتش لكل تمرين (جدول exercise_alternatives اللي تعدّله المدربة من لوحة الإدارة) في المتتبّع المجاني.
--    المتتبّع يقدّم للجميع بدائل عامة من نفس العضلة.
--  * «وجباتي»: وجبات قوالب التغذية (كانت لمن عنده برنامج أو اشترى «وجباتي»، وتبقى لهم).
-- الاستحقاق الآن: المدربة، أو متدرب باشتراك متابعة جارٍ (ميزة ضمن الباقة). اشتراك Apple يُضاف هنا لاحقاً.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.has_pro() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM orders o LEFT JOIN products p ON p.id = o.product_id
                                    WHERE o.user_id = app.uid() AND o.status = 'active' AND p.app_addon IS NULL);
$$;
REVOKE ALL ON FUNCTION app.has_pro() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_pro() TO nav_app;

-- اسم التمرين → أسماء بدائله بترتيب المدربة (المعتمدة فقط). NULL لغير المشترك.
CREATE OR REPLACE FUNCTION app.coach_alts() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN app.has_pro() THEN (
    SELECT coalesce(jsonb_object_agg(t.name, t.alts), '{}'::jsonb) FROM (
      SELECT e.name, jsonb_agg(x.name ORDER BY a.position, x.name) AS alts
        FROM exercise_alternatives a
        JOIN exercises e ON e.id = a.exercise_id AND e.status = 'approved'
        JOIN exercises x ON x.id = a.alt_id AND x.status = 'approved'
       GROUP BY e.name) t)
  END
$$;
REVOKE ALL ON FUNCTION app.coach_alts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_alts() TO nav_app;

-- «وجباتي»: من عنده برنامج (أو اشترى «وجباتي» من الموقع) أو مشترك «ناف برو»
CREATE OR REPLACE FUNCTION app.has_meals() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.has_program() OR app.has_pro();
$$;
REVOKE ALL ON FUNCTION app.has_meals() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_meals() TO nav_app;

-- نفس تعريف 034 مع الاستحقاق الجديد
CREATE OR REPLACE FUNCTION app.library_meals()
RETURNS TABLE (meal_id uuid, plan_name text, kind text, title text, protein numeric, carbs numeric, fat numeric, foods text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT DISTINCT ON (m.title, t.protein, t.carbs, t.fat) m.id, p.name, m.kind, m.title, t.protein, t.carbs, t.fat, t.foods
    FROM plan_meals m
    JOIN nutrition_plans p ON p.id = m.plan_id AND p.order_id IS NULL AND NOT p.archived
    JOIN LATERAL (SELECT coalesce(sum(i.protein), 0) AS protein, coalesce(sum(i.carbs), 0) AS carbs, coalesce(sum(i.fat), 0) AS fat,
                         string_agg(i.food, '، ' ORDER BY i.position) AS foods
                    FROM plan_items i WHERE i.meal_id = m.id) t ON true
   WHERE app.is_coach() OR app.has_meals()
   ORDER BY m.title, t.protein, t.carbs, t.fat, p.position, m.position;
$$;

CREATE OR REPLACE FUNCTION app.meal_details(p_meals uuid[])
RETURNS TABLE (meal_id uuid, method text, items jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m.id, m.method,
         coalesce((SELECT jsonb_agg(jsonb_build_object('food', i.food, 'portion', i.portion, 'protein', i.protein, 'carbs', i.carbs, 'fat', i.fat) ORDER BY i.position)
                     FROM plan_items i WHERE i.meal_id = m.id), '[]'::jsonb)
    FROM plan_meals m JOIN nutrition_plans p ON p.id = m.plan_id AND NOT p.archived
   WHERE m.id = ANY(p_meals)
     AND (app.is_coach() OR (app.has_meals() AND (p.order_id IS NULL OR EXISTS (SELECT 1 FROM orders o WHERE o.id = p.order_id AND o.user_id = app.uid()))));
$$;
