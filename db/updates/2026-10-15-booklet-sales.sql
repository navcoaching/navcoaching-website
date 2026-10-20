-- الكتيبات: لباقات المتابعة اللي تشملها فقط، وبيعها منفردة لغيرهم. يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '042_booklet_sales.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- الكتيبات: لمشتركي باقات المتابعة فقط، وتُباع منفردة لغيرهم.
-- - يفتح الكتيب: المدربة، أو من له اشتراك في باقة تشمل الكتيبات (الأساسية/المكثفة/المتقدمة؛ ويبقى بعد الانتهاء)،
--   أو من اشترى نفس الكتيب.
--   الباقات الأخرى (ملفات، استشارة، خدمات التطبيق) ما تفتحها بعد الآن.
-- - البيع: لكل كتيب منتج مخفي (category = files، products.booklet_id) بعرض واحد بسعره. الدفع بنفس مسار الطلبات.
--   منتج الكتيب ما يظهر في البرامج ولا الاستبيان (الفلترة في التطبيق)، ويُدار من صفحة الكتيبات فقط.
-- - الشراء يفتح الكتيب من تأكيد الدفع (قيد الإعداد فما بعد).
-- =====================================================================
ALTER TABLE products ADD COLUMN booklet_id uuid UNIQUE REFERENCES booklets (id) ON DELETE SET NULL;
-- الباقات اللي تشمل الكتيبات (الأساسية والمكثفة والمتقدمة)؛ المدربة تغيّرها من صفحة المنتج
ALTER TABLE products ADD COLUMN includes_booklets boolean NOT NULL DEFAULT false;
UPDATE products SET includes_booklets = true WHERE slug IN ('basic', 'intensive', 'advanced');

-- اشتراك في باقة تشمل الكتيبات (يبقى بعد انتهاء الاشتراك)
CREATE OR REPLACE FUNCTION app.has_follow_program() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM orders o JOIN products p ON p.id = o.product_id
     WHERE o.user_id = app.uid() AND p.includes_booklets AND o.status IN ('active', 'delivered', 'completed'));
$$;

-- اشترى هذا الكتيب (من تأكيد الدفع)
CREATE OR REPLACE FUNCTION app.bought_booklet(p_booklet uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT app.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM orders o JOIN products p ON p.id = o.product_id
     WHERE o.user_id = app.uid() AND p.booklet_id = p_booklet AND o.status IN ('preparing', 'active', 'delivered', 'completed'));
$$;

DROP POLICY IF EXISTS booklets_read ON booklets;
CREATE POLICY booklets_read ON booklets FOR SELECT USING (
  app.is_coach() OR (published AND app.has_follow_program()) OR app.bought_booklet(id)
);
REVOKE ALL ON FUNCTION app.has_follow_program() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.bought_booklet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_follow_program() TO nav_app;
GRANT EXECUTE ON FUNCTION app.bought_booklet(uuid) TO nav_app;

-- حذف كتيب: منتجه يُؤرشف (الطلبات السابقة تبقى كما هي)
CREATE OR REPLACE FUNCTION app.booklet_archive_product() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE products SET status = 'archived', updated_at = now() WHERE booklet_id = OLD.id;
  RETURN OLD;
END $$;
CREATE TRIGGER booklets_archive_product BEFORE DELETE ON booklets FOR EACH ROW EXECUTE FUNCTION app.booklet_archive_product();

-- المدربة: سعر البيع (NULL أو 0 = غير معروض للبيع). ينشئ/يحدّث منتج الكتيب وعرضه، ويتبع اسمه وظهوره
CREATE OR REPLACE FUNCTION app.coach_set_booklet_price(p_booklet uuid, p_price_halalas int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_coach text := app.require_coach();
  v_b booklets%ROWTYPE;
  v_product uuid;
  v_tag text;
  v_status text;
BEGIN
  SELECT * INTO v_b FROM booklets WHERE id = p_booklet;
  IF NOT FOUND THEN RAISE EXCEPTION 'الكتيب غير موجود.' USING ERRCODE = 'P0001'; END IF;
  IF p_price_halalas IS NOT NULL AND (p_price_halalas < 0 OR p_price_halalas > 10000000) THEN
    RAISE EXCEPTION 'السعر غير صالح.' USING ERRCODE = 'P0001';
  END IF;
  v_status := CASE WHEN coalesce(p_price_halalas, 0) > 0 AND v_b.published THEN 'published' ELSE 'draft' END;
  v_tag := left(replace(v_b.id::text, '-', ''), 12);
  SELECT id INTO v_product FROM products WHERE booklet_id = p_booklet;
  IF v_product IS NULL THEN
    IF coalesce(p_price_halalas, 0) = 0 THEN RETURN; END IF;
    INSERT INTO products (slug, category, name, audience, status, booklet_id, delivery)
    VALUES ('booklet-' || v_tag, 'files', 'كتيب: ' || v_b.title, '', v_status, p_booklet, 'ملف PDF يُحمّل من «حسابي» بعد تأكيد الدفع.')
    RETURNING id INTO v_product;
    INSERT INTO product_offers (product_id, sku, label, months, price_halalas)
    VALUES (v_product, 'bk-' || v_tag, 'ملف PDF', 0, p_price_halalas);
  ELSE
    UPDATE products SET name = 'كتيب: ' || v_b.title, status = v_status, updated_at = now() WHERE id = v_product;
    UPDATE product_offers SET price_halalas = CASE WHEN coalesce(p_price_halalas, 0) > 0 THEN p_price_halalas ELSE price_halalas END,
                              active = coalesce(p_price_halalas, 0) > 0
     WHERE product_id = v_product;
  END IF;
  INSERT INTO admin_log (actor_id, action, target, details)
  VALUES (v_coach, 'booklet.price', v_b.title, jsonb_build_object('price_halalas', p_price_halalas));
END $$;
REVOKE ALL ON FUNCTION app.coach_set_booklet_price(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.coach_set_booklet_price(uuid, int) TO nav_app;

-- الصفحة العامة: الكتيبات المعروضة للبيع (بدون مفتاح الملف)، مع حالة المستخدم الحالي إن وُجد
CREATE OR REPLACE FUNCTION app.booklets_for_sale()
RETURNS TABLE (id uuid, title text, description text, file_size int, sku text, price_halalas int, owned boolean, pending_order text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT b.id, b.title, b.description, b.file_size, o.sku, o.price_halalas,
         app.has_follow_program() OR app.bought_booklet(b.id),
         (SELECT x.order_no FROM orders x WHERE app.uid() IS NOT NULL AND x.user_id = app.uid() AND x.product_id = p.id
             AND x.status IN ('awaiting_quote', 'awaiting_payment', 'payment_review') ORDER BY x.created_at DESC LIMIT 1)
    FROM booklets b
    JOIN products p ON p.booklet_id = b.id AND p.status = 'published'
    JOIN product_offers o ON o.product_id = p.id AND o.active AND o.price_halalas > 0
   WHERE b.published
   ORDER BY b.sort, b.created_at
$$;
REVOKE ALL ON FUNCTION app.booklets_for_sale() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.booklets_for_sale() TO nav_app;
INSERT INTO schema_migrations (name) VALUES ('042_booklet_sales.sql');
COMMIT;

-- للتأكد: يرجع اسم الملف، والباقات اللي تشمل الكتيبات (المتوقع: advanced, basic, intensive)
SELECT (SELECT max(name) FROM schema_migrations) AS last,
       (SELECT string_agg(slug, ', ' ORDER BY slug) FROM products WHERE includes_booklets) AS with_booklets;
