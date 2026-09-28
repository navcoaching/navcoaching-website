-- =====================================================================
-- رسالة من المدربة للمتدرب: تُحفظ كتحديث ظاهر للمتدرب في صفحة طلبه (order_events)
-- بدون تغيير حالة الطلب (from_status = to_status = الحالة الحالية).
-- =====================================================================

CREATE OR REPLACE FUNCTION app.coach_message(p_order_no text, p_text text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid text := app.require_coach();
  v_order orders%ROWTYPE;
  v_text text := trim(coalesce(p_text, ''));
BEGIN
  IF length(v_text) < 2 OR length(v_text) > 2000 THEN
    RAISE EXCEPTION 'اكتبي الرسالة (حتى 2000 حرف).' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note, client_visible)
  VALUES (v_order.id, v_order.status, v_order.status, v_uid, 'coach', v_text, true);
END $$;
REVOKE ALL ON FUNCTION app.coach_message(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_message(text, text) TO nav_app;
