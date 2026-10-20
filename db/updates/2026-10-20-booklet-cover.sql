-- غلاف الكتيب (صورة اختيارية). يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '045_booklet_cover.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- غلاف الكتيب: صورة اختيارية ترفعها المدربة مع الكتيب، تظهر في صفحة البيع و«حسابي».
-- الصورة في media_assets (usage = 'booklet') ومعتمدة للنشر، وتنحذف مع الكتيب أو عند استبدالها (من التطبيق).
-- =====================================================================
ALTER TABLE media_assets DROP CONSTRAINT IF EXISTS media_assets_usage_check;
ALTER TABLE media_assets ADD CONSTRAINT media_assets_usage_check
  CHECK (usage IN ('hero', 'about', 'gallery', 'product', 'free_plan', 'booklet'));
ALTER TABLE booklets ADD COLUMN cover_id uuid REFERENCES media_assets (id) ON DELETE SET NULL;

DROP FUNCTION app.booklets_for_sale();
CREATE FUNCTION app.booklets_for_sale()
RETURNS TABLE (id uuid, title text, description text, file_size int, sku text, price_halalas int, owned boolean, pending_order text, cover_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT b.id, b.title, b.description, b.file_size, o.sku, o.price_halalas,
         app.has_follow_program() OR app.bought_booklet(b.id),
         (SELECT x.order_no FROM orders x WHERE app.uid() IS NOT NULL AND x.user_id = app.uid() AND x.product_id = p.id
             AND x.status IN ('awaiting_quote', 'awaiting_payment', 'payment_review') ORDER BY x.created_at DESC LIMIT 1),
         b.cover_id
    FROM booklets b
    JOIN products p ON p.booklet_id = b.id AND p.status = 'published'
    JOIN product_offers o ON o.product_id = p.id AND o.active AND o.price_halalas > 0
   WHERE b.published
   ORDER BY b.sort, b.created_at
$$;
REVOKE ALL ON FUNCTION app.booklets_for_sale() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.booklets_for_sale() TO nav_app;
INSERT INTO schema_migrations (name) VALUES ('045_booklet_cover.sql');
COMMIT;

-- للتأكد: يرجع 045_booklet_cover.sql و true
SELECT (SELECT max(name) FROM schema_migrations) AS last, EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'booklets' AND column_name = 'cover_id') AS has_cover;
