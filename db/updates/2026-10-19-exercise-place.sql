-- تصنيف التمارين: البيت أو النادي، ومكان للقالب والبرنامج. يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '043_exercise_place.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
-- =====================================================================
-- تصنيف التمارين: «البيت» أو «النادي» فقط، وقالب/برنامج المتدرب له مكان.
-- - البيت: وزن الجسم، الدمبل والكيتلبل، الباند، البار والبنش، والأدوات الصغيرة (كرة سويسرية، TRX، عقلة).
-- - النادي: الأجهزة والكيبل والسميث، وأي تمرين باسمه جهاز (Machine, Cable, Leg Press, Pulldown, Sled…).
-- - برنامج «البيت»: بدائل المتدرب عند التبديل من تمارين البيت فقط، والمدربة تضيف من تمارين البيت فقط.
-- =====================================================================

-- المكان يُحسب من المعدات واسم التمرين (نفس منطق placeFor في src/lib/exercises.ts)
CREATE OR REPLACE FUNCTION app.exercise_place(p_equipment text, p_name text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(p_name, '') ~* '\mband' THEN 'منزل'
    WHEN p_equipment IN ('جهاز', 'كيبل', 'سميث') THEN 'نادي'
    WHEN coalesce(p_name, '') ~* '(machine|cable|smith|leg press|pulldown|pull-down|pec deck|sled|hack squat|wall ball)' THEN 'نادي'
    ELSE 'منزل'
  END
$$;

-- القيم القديمة («بدون معدات» وغيرها) تُحوَّل تلقائياً، والمدربة تقدر تختار المكان يدوياً من صفحة التمرين
CREATE OR REPLACE FUNCTION app.exercise_place_norm() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.place IS NULL OR NEW.place NOT IN ('منزل', 'نادي') THEN
    NEW.place := app.exercise_place(NEW.equipment, NEW.name);
  END IF;
  RETURN NEW;
END $$;

ALTER TABLE exercises DROP CONSTRAINT IF EXISTS exercises_place_check;
UPDATE exercises SET place = app.exercise_place(equipment, name);
ALTER TABLE exercises ALTER COLUMN place SET NOT NULL;
ALTER TABLE exercises ADD CONSTRAINT exercises_place_check CHECK (place IN ('منزل', 'نادي'));
CREATE TRIGGER exercises_place_norm BEFORE INSERT OR UPDATE ON exercises FOR EACH ROW EXECUTE FUNCTION app.exercise_place_norm();

-- مكان القالب والبرنامج (البرنامج ينسخ مكان قالبه عند الإسناد)
ALTER TABLE program_templates ADD COLUMN place text NOT NULL DEFAULT 'نادي' CHECK (place IN ('منزل', 'نادي'));
UPDATE program_templates SET place = 'منزل' WHERE name ~* '(منزل|بيت|home)';
ALTER TABLE blocks ADD COLUMN place text NOT NULL DEFAULT 'نادي' CHECK (place IN ('منزل', 'نادي'));
UPDATE blocks b SET place = t.place FROM program_templates t WHERE t.id = b.template_id;
UPDATE blocks SET place = 'منزل' WHERE template_id IS NULL AND name ~* '(منزل|بيت|home)';

CREATE OR REPLACE FUNCTION app.block_place_from_template() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.template_id IS NOT NULL THEN
    SELECT t.place INTO NEW.place FROM program_templates t WHERE t.id = NEW.template_id;
    NEW.place := coalesce(NEW.place, 'نادي');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER blocks_place_from_template BEFORE INSERT ON blocks FOR EACH ROW EXECUTE FUNCTION app.block_place_from_template();

-- بدائل المتدرب: برنامج البيت يعرض تمارين البيت فقط (اختيار المدربة الأصلي يبقى دائماً)
CREATE OR REPLACE FUNCTION app.swap_options(p_item uuid)
RETURNS TABLE (id uuid, name text, video_url text, is_coach_choice boolean, is_current boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_item block_items%ROWTYPE;
  v_base exercises%ROWTYPE;
  v_home boolean;
BEGIN
  SELECT * INTO v_item FROM block_items WHERE block_items.id = p_item;
  IF NOT FOUND OR NOT app.block_visible(app.item_block(p_item)) THEN RETURN; END IF;
  SELECT * INTO v_base FROM exercises WHERE exercises.id = v_item.coach_exercise_id;
  SELECT b.place = 'منزل' INTO v_home FROM block_days d JOIN blocks b ON b.id = d.block_id WHERE d.id = v_item.day_id;
  IF EXISTS (SELECT 1 FROM exercise_alternatives a WHERE a.exercise_id = v_base.id) THEN
    RETURN QUERY
      SELECT v_base.id, v_base.name, v_base.video_url, true, v_base.id = v_item.exercise_id
      UNION ALL
      SELECT e.id, e.name, e.video_url, false, e.id = v_item.exercise_id
        FROM (SELECT a.alt_id, a.position FROM exercise_alternatives a WHERE a.exercise_id = v_base.id ORDER BY a.position) x
        JOIN exercises e ON e.id = x.alt_id AND e.status = 'approved' AND (NOT coalesce(v_home, false) OR e.place = 'منزل');
  ELSE
    RETURN QUERY
      SELECT v_base.id, v_base.name, v_base.video_url, true, v_base.id = v_item.exercise_id
      UNION ALL
      (SELECT e.id, e.name, e.video_url, false, e.id = v_item.exercise_id
         FROM exercises e
        WHERE e.status = 'approved' AND e.id <> v_base.id AND e.primary_muscle = v_base.primary_muscle
          AND e.pattern IS NOT DISTINCT FROM v_base.pattern
          AND (NOT coalesce(v_home, false) OR e.place = 'منزل')
        ORDER BY e.name LIMIT 8);
  END IF;
END $$;
INSERT INTO schema_migrations (name) VALUES ('043_exercise_place.sql');
COMMIT;

-- للتأكد: اسم الملف، وعدد تمارين البيت والنادي، والقوالب اللي صارت للبيت
SELECT (SELECT max(name) FROM schema_migrations) AS last,
       (SELECT count(*) FROM exercises WHERE place = 'منزل') AS home,
       (SELECT count(*) FROM exercises WHERE place = 'نادي') AS gym,
       (SELECT string_agg(name, '، ') FROM program_templates WHERE place = 'منزل') AS home_templates;
