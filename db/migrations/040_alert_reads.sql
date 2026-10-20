-- =====================================================================
-- «تمت القراءة» لتنبيهات المتابعة في لوحة الإدارة.
-- التنبيهات تُحسب وقت فتح الصفحة (ما لها جدول)، فنحفظ مفتاح كل تنبيه قرأته المدربة ويختفي.
-- المفتاح يتغيّر إذا تغيّر سبب التنبيه (مثل مراجعة أسبوع جديد)، فيظهر التنبيه الجديد عادي.
-- =====================================================================
CREATE TABLE IF NOT EXISTS coach_alert_reads (
  key text PRIMARY KEY CHECK (length(key) BETWEEN 3 AND 200),
  read_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE coach_alert_reads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS alert_reads_coach ON coach_alert_reads;
CREATE POLICY alert_reads_coach ON coach_alert_reads FOR ALL USING (app.is_coach()) WITH CHECK (app.is_coach());
GRANT SELECT, INSERT, DELETE ON coach_alert_reads TO nav_app;
