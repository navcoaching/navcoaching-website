-- =====================================================================
-- تعديل ملاحظة المدربة الخاصة: النص يُستبدل ويُحفظ وقت آخر تعديل، وتاريخ الكتابة الأصلي يبقى.
-- للمدربة فقط عبر دالة تتحقق داخل قاعدة البيانات، والتعديل يُسجَّل في admin_log.
-- =====================================================================

ALTER TABLE order_note_entries ADD COLUMN IF NOT EXISTS updated_at timestamptz;

CREATE OR REPLACE FUNCTION app.coach_update_note(p_id bigint, p_body text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_order uuid;
BEGIN
  IF coalesce(trim(p_body), '') = '' THEN RAISE EXCEPTION 'اكتبي الملاحظة أولاً.' USING ERRCODE = 'P0001'; END IF;
  IF length(p_body) > 5000 THEN RAISE EXCEPTION 'الملاحظة أطول من 5000 حرف.' USING ERRCODE = 'P0001'; END IF;
  UPDATE order_note_entries SET body = trim(p_body), updated_at = now() WHERE id = p_id RETURNING order_id INTO v_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'الملاحظة غير موجودة.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'note.update', v_order::text, jsonb_build_object('id', p_id));
END $$;

REVOKE ALL ON FUNCTION app.coach_update_note(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_update_note(bigint, text) TO nav_app;
