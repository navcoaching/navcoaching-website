-- مقياس الألم بعد التمرين (0–10). يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '047_item_pain.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- مقياس الألم بعد التمرين (0–10) لمنطقة الشكوى المكتوبة (مثل «ألم الركبة» أو «ألم المرفق»).
-- pain_label على تمرين القالب أو البلوك = يظهر للمتدرب حقل الألم بعد تسجيل هذا التمرين، فارغ = بدون مقياس.
-- القيمة في item_logs.pain، ويسجّلها المتدرب عبر app.set_item_pain فقط (بعد تسجيل التمرين نفسه).
-- =====================================================================

ALTER TABLE template_items ADD COLUMN IF NOT EXISTS pain_label text CHECK (pain_label IS NULL OR length(pain_label) BETWEEN 2 AND 40);
ALTER TABLE block_items ADD COLUMN IF NOT EXISTS pain_label text CHECK (pain_label IS NULL OR length(pain_label) BETWEEN 2 AND 40);
ALTER TABLE item_logs ADD COLUMN IF NOT EXISTS pain smallint CHECK (pain IS NULL OR pain BETWEEN 0 AND 10);

-- نفس تحقق log_item_sets: تمرين في بلوك المتدرب النشط وأسبوع صحيح، والتمرين عليه مقياس ألم ومسجّل هذا الأسبوع
CREATE OR REPLACE FUNCTION app.set_item_pain(p_item uuid, p_week int, p_pain int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_block blocks%ROWTYPE;
  v_label text;
BEGIN
  SELECT pain_label INTO v_label FROM block_items WHERE id = p_item;
  IF NOT FOUND THEN RAISE EXCEPTION 'التمرين غير موجود.' USING ERRCODE = 'P0001'; END IF;
  v_block := app.my_active_block(app.item_block(p_item));
  PERFORM app.check_week(v_block, p_week);
  IF v_label IS NULL THEN RAISE EXCEPTION 'لا يوجد مقياس ألم لهذا التمرين.' USING ERRCODE = 'P0001'; END IF;
  IF p_pain IS NOT NULL AND (p_pain < 0 OR p_pain > 10) THEN RAISE EXCEPTION 'الألم رقم من 0 إلى 10.' USING ERRCODE = 'P0001'; END IF;
  UPDATE item_logs SET pain = p_pain WHERE block_item_id = p_item AND week_no = p_week;
  IF NOT FOUND THEN RAISE EXCEPTION 'سجّل التمرين أولاً.' USING ERRCODE = 'P0001'; END IF;
END $$;
REVOKE ALL ON FUNCTION app.set_item_pain(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_item_pain(uuid, int, int) TO nav_app;

-- إسناد القالب ينسخ مقياس الألم مع التمرين (باقي الدالة كما في 009 بدون تغيير)
CREATE OR REPLACE FUNCTION app.coach_assign_template(p_order_no text, p_template uuid, p_start date, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order orders%ROWTYPE;
  v_tpl program_templates%ROWTYPE;
  v_block uuid;
  d record;
  v_day uuid;
BEGIN
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_tpl FROM program_templates WHERE id = p_template;
  IF NOT FOUND THEN RAISE EXCEPTION 'القالب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_start IS NULL THEN RAISE EXCEPTION 'اختاري تاريخ البداية.' USING ERRCODE = 'P0001'; END IF;
  IF NOT EXISTS (SELECT 1 FROM template_days td JOIN template_items ti ON ti.day_id = td.id WHERE td.template_id = p_template) THEN
    RAISE EXCEPTION 'القالب فارغ: أضيفي أياماً وتمارين أولاً.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE blocks SET status = 'archived', updated_at = now() WHERE order_id = v_order.id AND status = 'active';
  INSERT INTO blocks (order_id, user_id, template_id, name, start_date, weeks, instructions)
  VALUES (v_order.id, v_order.user_id, v_tpl.id, coalesce(nullif(trim(p_name), ''), v_tpl.name), p_start, v_tpl.weeks, v_tpl.instructions)
  RETURNING id INTO v_block;
  FOR d IN SELECT * FROM template_days WHERE template_id = p_template ORDER BY day_no LOOP
    INSERT INTO block_days (block_id, day_no, title) VALUES (v_block, d.day_no, d.title) RETURNING id INTO v_day;
    INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan, note, pain_label)
    SELECT v_day, ti.position, ti.exercise_id, ti.exercise_id, ti.plan, ti.note, ti.pain_label FROM template_items ti WHERE ti.day_id = d.id;
  END LOOP;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'block.assign', p_order_no, jsonb_build_object('template', v_tpl.name, 'start', p_start));
  RETURN v_block;
END $$;

INSERT INTO schema_migrations (name) VALUES ('047_item_pain.sql');
COMMIT;
