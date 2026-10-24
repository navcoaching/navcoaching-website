-- النسخة الإنجليزية: عمود i18n في جداول المحتوى العام. الشكل: {"en": {...الحقول المترجمة...}}.
-- الحقول الناقصة في الترجمة تُعرض بالعربية. المحتوى الإنجليزي الأولي يُستورد من db/seed/source/en (scripts/seed.mjs)
-- وفي الإنتاج من db/updates/2026-10-24-i18n.sql.
ALTER TABLE products      ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE faqs          ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE policies      ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE site_settings ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE free_plans    ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE booklets      ADD COLUMN IF NOT EXISTS i18n jsonb NOT NULL DEFAULT '{}'::jsonb;

-- الجداول المجانية تُحفظ عبر دالة، فالترجمة تحتاج صلاحية تحديث العمود فقط للمدربة
GRANT SELECT (i18n), UPDATE (i18n) ON free_plans TO nav_app;
DROP POLICY IF EXISTS free_plans_i18n ON free_plans;
CREATE POLICY free_plans_i18n ON free_plans FOR UPDATE USING (app.is_coach()) WITH CHECK (app.is_coach());
