-- حذف تمرين «left over db» من المكتبة (تمرين غير حقيقي). يُحذف فقط إذا لا يستخدمه أي قالب أو برنامج متدرب، وإلا لا يُحذف (ويظهر عدد المواضع).
BEGIN;
DO $g$
DECLARE v_id uuid; v_used int;
BEGIN
  SELECT id INTO v_id FROM exercises WHERE lower(trim(name)) = 'left over db';
  IF v_id IS NULL THEN RAISE NOTICE 'التمرين غير موجود أصلاً.'; RETURN; END IF;
  SELECT (SELECT count(*) FROM template_items WHERE exercise_id = v_id)
       + (SELECT count(*) FROM block_items WHERE exercise_id = v_id OR coach_exercise_id = v_id) INTO v_used;
  IF v_used > 0 THEN
    RAISE EXCEPTION 'التمرين مستخدم في % موضع (قوالب أو برامج متدربين)، فلم يُحذف. اضغطي ROLLBACK.', v_used;
  END IF;
  DELETE FROM exercises WHERE id = v_id;
END $g$;
COMMIT;
