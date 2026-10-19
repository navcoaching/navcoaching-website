-- قفل البرنامج لين تاريخ البداية المختار. يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '041_program_start_lock.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- الاشتراك اللي اختار فيه المتدرب «تاريخ أحدده»: البرنامج (التمرين والتغذية والمكملات) ما يظهر له
-- ولا يقبل تسجيلاً إلا من تاريخ بداية الاشتراك، حتى لو أسندته المدربة قبلها.
-- - المرجع: تاريخ بداية الاشتراك بتوقيت الرياض (sub_start_at)؛ فإذا غيّرته المدربة لتاريخ أبكر ينفتح من تاريخها.
-- - «بأقرب وقت» (preferred_start فارغ) والتجديد بدون تاريخ مختار: لا تغيير.
-- - المدربة تشوف كل شي دائماً.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.program_started(p_order uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM orders o
     WHERE o.id = p_order AND o.preferred_start IS NOT NULL AND o.sub_start_at IS NOT NULL
       AND (o.sub_start_at AT TIME ZONE 'Asia/Riyadh')::date > (now() AT TIME ZONE 'Asia/Riyadh')::date)
$$;
REVOKE ALL ON FUNCTION app.program_started(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.program_started(uuid) TO nav_app;

CREATE OR REPLACE FUNCTION app.block_visible(p_block uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM blocks b WHERE b.id = p_block AND app.order_entitled(b.order_id) AND app.program_started(b.order_id))
$$;

CREATE OR REPLACE FUNCTION app.plan_visible(p_plan uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.id = p_plan AND p.order_id IS NOT NULL AND NOT p.archived
                                    AND app.order_entitled(p.order_id) AND app.program_started(p.order_id))
$$;

CREATE OR REPLACE FUNCTION app.routine_visible(p_routine uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.is_coach() OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.id = p_routine AND r.order_id IS NOT NULL AND NOT r.archived
                                    AND app.order_entitled(r.order_id) AND app.program_started(r.order_id))
$$;

DROP POLICY IF EXISTS targets_read ON nutrition_targets;
CREATE POLICY targets_read ON nutrition_targets FOR SELECT USING (
  app.is_coach() OR (app.order_entitled(order_id) AND app.program_started(order_id) AND (kcal_source <> 'auto' OR kcal_confirmed_at IS NOT NULL))
);

-- التسجيل على البرنامج (التمارين، تقييم اليوم، الخطوات…) يمر على my_active_block: يُرفض قبل تاريخ البداية
CREATE OR REPLACE FUNCTION app.my_active_block(p_block uuid) RETURNS blocks
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v blocks%ROWTYPE;
BEGIN
  PERFORM app.require_user();
  SELECT * INTO v FROM blocks WHERE id = p_block;
  IF NOT FOUND OR v.user_id <> app.uid() OR NOT app.order_entitled(v.order_id) THEN
    RAISE EXCEPTION 'البرنامج غير موجود.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT app.program_started(v.order_id) THEN
    RAISE EXCEPTION 'برنامجك يبدأ من تاريخ بداية الاشتراك.' USING ERRCODE = 'P0001';
  END IF;
  IF v.status <> 'active' THEN RAISE EXCEPTION 'هذا البرنامج منتهي ولا يقبل تعديلات.' USING ERRCODE = 'P0001'; END IF;
  RETURN v;
END $$;
INSERT INTO schema_migrations (name) VALUES ('041_program_start_lock.sql');
COMMIT;

-- للتأكد: يرجع 041_program_start_lock.sql
SELECT max(name) FROM schema_migrations;
