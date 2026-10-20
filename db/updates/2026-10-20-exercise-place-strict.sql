-- تصحيح تصنيف التمارين (البيت/النادي) وإعادة تصنيف كل التمارين. يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '046_exercise_place_strict.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- تصحيح تصنيف التمارين: «البيت» فقط للتمارين بـ: بار، دمبل، بنش، كيتلبل، TRX، باند، وزن الجسم.
-- أي شيء غيرها (أجهزة، كيبل، سميث، معدات أخرى أو غير محددة) = «النادي». يعاد تصنيف كل التمارين.
-- =====================================================================

-- نفس منطق placeFor في src/lib/exercises.ts
CREATE OR REPLACE FUNCTION app.exercise_place(p_equipment text, p_name text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(p_name, '') ~* '\mband' THEN 'منزل'
    WHEN p_equipment IN ('بار', 'دمبل', 'كيتلبل', 'TRX', 'مطاط', 'وزن الجسم') THEN 'منزل'
    WHEN coalesce(p_name, '') ~* '(machine|cable|smith|leg press|pulldown|pull-down|pec deck|sled|hack squat|wall ball)' THEN 'نادي'
    WHEN coalesce(p_name, '') ~* '(dumbbell|\mdb\M|barbell|kettlebell|\mkb\M|trx|bench|bodyweight)' THEN 'منزل'
    ELSE 'نادي'
  END
$$;

UPDATE exercises SET place = app.exercise_place(equipment, name) WHERE place IS DISTINCT FROM app.exercise_place(equipment, name);
INSERT INTO schema_migrations (name) VALUES ('046_exercise_place_strict.sql');
COMMIT;

-- للتأكد: عدد التمارين في كل مكان
SELECT place, count(*) FROM exercises GROUP BY place;
