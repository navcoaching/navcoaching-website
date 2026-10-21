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
