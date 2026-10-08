-- نقل طلب لحساب صاحبته الصحيح + تعديل اسم الحساب (للمدربة فقط). يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '035_move_order.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- نقل طلب لحساب صاحبه الصحيح (للمدربة فقط)
-- يحدث عند إضافة طلب يدوي ببريد شخص آخر، أو طلب أرسلته متدربة من حساب غيرها (جوال مشترك مثلاً).
-- ينقل الطلب وكل ما يتبعه (البرنامج والمراجعات والاستبيان والتغذية والإيصالات...) لحساب البريد المحدد،
-- وينشئ الحساب إن لم يكن موجوداً. لا يحذف شيئاً، ويُسجَّل في سجل الإدارة وسجل الطلب.
-- =====================================================================
CREATE OR REPLACE FUNCTION app.coach_move_order(p_order_no text, p_email text, p_name text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_name text := trim(coalesce(p_name, ''));
  v_order orders%ROWTYPE;
  v_from "user"%ROWTYPE;
  v_to "user"%ROWTYPE;
BEGIN
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 200 THEN
    RAISE EXCEPTION 'اكتبي بريد صاحبة الطلب الصحيح.' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_order FROM orders WHERE order_no = p_order_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_from FROM "user" WHERE id = v_order.user_id;

  SELECT * INTO v_to FROM "user" WHERE lower(email) = v_email;
  IF NOT FOUND THEN
    IF length(v_name) NOT BETWEEN 2 AND 80 THEN
      RAISE EXCEPTION 'هذا البريد غير مسجّل؛ اكتبي اسم صاحبة الطلب لإنشاء حسابها.' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO "user" (id, name, email, "emailVerified", role, phone)
    VALUES (gen_random_uuid()::text, v_name, v_email, false, 'client', nullif(v_order.contact_phone, ''))
    RETURNING * INTO v_to;
  ELSIF v_to.role <> 'client' THEN
    RAISE EXCEPTION 'هذا البريد لحساب إداري، وليس لمتدرب.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to.id = v_order.user_id THEN
    RAISE EXCEPTION 'الطلب أصلاً في حساب هذا البريد.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE orders SET user_id = v_to.id, updated_at = now() WHERE id = v_order.id;
  UPDATE blocks SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE exercise_swaps SET user_id = v_to.id WHERE block_id IN (SELECT id FROM blocks WHERE order_id = v_order.id);
  UPDATE check_ins SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE exit_surveys SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE food_logs SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE intakes SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE notification_log SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE payment_proofs SET user_id = v_to.id WHERE order_id = v_order.id;
  UPDATE reviews SET user_id = v_to.id WHERE order_id = v_order.id;

  -- اسم الحساب الجديد: إن كان فارغاً أو مأخوذاً من البريد يأخذ الاسم المكتوب
  IF length(v_name) BETWEEN 2 AND 80 AND (v_to.name = '' OR v_to.name = split_part(v_to.email, '@', 1)) THEN
    UPDATE "user" SET name = v_name, "updatedAt" = now() WHERE id = v_to.id;
  END IF;

  INSERT INTO order_events (order_id, from_status, to_status, actor_id, actor_role, note, client_visible)
  VALUES (v_order.id, v_order.status, v_order.status, v_coach, 'coach', 'نُقل الطلب لحساب صاحبته الصحيح (' || v_to.email || ').', false);
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'order.move', v_order.order_no,
          jsonb_build_object('from_user', v_order.user_id, 'from_email', v_from.email, 'to_user', v_to.id, 'to_email', v_to.email));
  RETURN v_to.email;
END $$;
REVOKE ALL ON FUNCTION app.coach_move_order(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_move_order(text, text, text) TO nav_app;

-- تعديل اسم حساب متدرب (مثلاً حساب أخذ اسم شخص آخر بالخطأ)
CREATE OR REPLACE FUNCTION app.coach_rename_member(p_user_id text, p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_name text := trim(coalesce(p_name, ''));
BEGIN
  IF length(v_name) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'الاسم بين حرفين و80 حرفاً.' USING ERRCODE = 'P0001'; END IF;
  UPDATE "user" SET name = v_name, "updatedAt" = now() WHERE id = p_user_id AND role = 'client';
  IF NOT FOUND THEN RAISE EXCEPTION 'الحساب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO admin_log (actor_id, action, target, details) VALUES (v_coach, 'member.rename', p_user_id, jsonb_build_object('name', v_name));
END $$;
REVOKE ALL ON FUNCTION app.coach_rename_member(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_rename_member(text, text) TO nav_app;

INSERT INTO schema_migrations (name) VALUES ('035_move_order.sql');
COMMIT;
