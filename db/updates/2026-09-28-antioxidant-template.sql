-- قالب مضادات الأكسدة: فطور وغداء وعشاء وسناك من وصفات غنية بمصادر مضادات الأكسدة (الأرقام محسوبة من قاعدة الأكل).
-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف recipe-templates. يضيف القالب، أو يحدّث وجباته إذا كان موجوداً (نسخ المتدربين ما تتأثر). آمن لو انشغّل مرتين.
BEGIN;
DO $do$
DECLARE
  d jsonb := $rt$[{"name":"قالب مضادات الأكسدة","notes":"وصفات غنية بمصادر مضادات الأكسدة (توت، رمان، سبانخ، طماطم، فلفل أحمر، شوكولاتة داكنة، مكسرات، زيت زيتون). الأرقام محسوبة من مكونات كل وصفة بقاعدة بيانات USDA. المجموع تقريباً 1739 سعرة (بروتين 123غ، كارب 160غ، دهون 68غ).","meals":[{"kind":"breakfast","title":"شكشوكة بالسبانخ والفلفل الأحمر","method":"المكونات:\n• 200غ طماطم مقطّعة\n• 60غ فلفل رومي أحمر\n• 50غ بصل\n• 60غ سبانخ\n• بيضتين (100غ)\n• 1 ملعقة صغيرة زيت زيتون (5غ)\n• رغيف عربي بر صغير (64غ)\n• ملح وفلفل أسود وكمون\n\nالطريقة:\n1. نسخّن زيت الزيتون بمقلاة ونقلّب البصل لين يذبل.\n2. نضيف الفلفل والطماطم ونطبخهم على نار متوسطة لين يصيرون مثل الصوص.\n3. نضيف السبانخ ونقلّب دقيقة لين تذبل.\n4. نسوي فجوتين بالصوص ونكسر فيهم البيض، ونغطي المقلاة ونطبخ لين يتماسك البياض.\n5. نقدّمها مع الخبز العربي.\n\nملاحظة: القيم محسوبة من مكوناتها بقاعدة بيانات USDA. الأعشاب والتوابل وعصير الليمون غير محسوبة.","items":[{"food":"شكشوكة بالسبانخ والفلفل الأحمر","portion":"وجبة كاملة","protein":23.6,"carbs":54.7,"fat":16.5}]},{"kind":"lunch","title":"سلمون مشوي مع كينوا وسبانخ وطماطم","method":"المكونات:\n• 150غ سلمون (وزنه بعد الطبخ)\n• 120غ كينوا مطبوخة\n• 60غ سبانخ\n• 100غ طماطم\n• 1 ملعقة صغيرة زيت زيتون (5غ)\n• ملح وفلفل أسود وعصير ليمون\n\nالطريقة:\n1. نتبّل السلمون بالملح والفلفل والليمون ونشويه بالفرن أو بالمقلاة لين ينضج.\n2. نطبخ الكينوا بماء مملّح خفيف (جزء كينوا وجزئين ماء) لين تلين.\n3. بمقلاة نسخّن زيت الزيتون ونقلّب السبانخ والطماطم المقطّعة دقيقتين لين تذبل.\n4. نقدّم السلمون فوق الكينوا مع الخضار.\n\nملاحظة: القيم محسوبة من مكوناتها بقاعدة بيانات USDA. الأعشاب والتوابل وعصير الليمون غير محسوبة.","items":[{"food":"سلمون مشوي مع كينوا وسبانخ وطماطم","portion":"وجبة كاملة","protein":41.1,"carbs":31.6,"fat":26.3}]},{"kind":"dinner","title":"سلطة عدس بالدجاج والخضار الملوّنة","method":"المكونات:\n• 150غ عدس مطبوخ\n• 120غ صدر دجاج مشوي ومقطّع\n• 60غ فلفل رومي أحمر\n• 80غ طماطم\n• 60غ خيار\n• 20غ بصل\n• 1 ملعقة صغيرة زيت زيتون (5غ)\n• عصير ليمون وبقدونس وملح وفلفل\n\nالطريقة:\n1. نقطّع الفلفل والطماطم والخيار والبصل مكعبات صغيرة.\n2. بوعاء كبير نخلط العدس مع الخضار وشرايح الدجاج.\n3. نتبّل بزيت الزيتون وعصير الليمون والبقدونس والملح والفلفل ونحرّك زين.\n4. نتركها 10 دقايق بالثلاجة عشان تتشرب النكهات.\n\nملاحظة: القيم محسوبة من مكوناتها بقاعدة بيانات USDA. الأعشاب والتوابل وعصير الليمون غير محسوبة.","items":[{"food":"سلطة عدس بالدجاج والخضار الملوّنة","portion":"وجبة كاملة","protein":52.7,"carbs":40.9,"fat":10.3}]},{"kind":"snack","title":"طبق توت وفراولة مع شوكولاتة داكنة ولوز","method":"المكونات:\n• 100غ توت أزرق\n• 100غ فراولة\n• 15غ شوكولاتة داكنة (70–85%)\n• 15غ لوز\n\nالطريقة:\n1. نغسل التوت والفراولة ونقطّع الفراولة.\n2. نحطهم بطبق ونكسّر الشوكولاتة الداكنة فوقهم.\n3. نضيف اللوز ونقدّمه.","items":[{"food":"طبق توت وفراولة مع شوكولاتة داكنة ولوز","portion":"طبق","protein":5.8,"carbs":32.3,"fat":14.5}]}]}]$rt$::jsonb;
  p jsonb; m jsonb; it jsonb;
  v_plan uuid; v_meal uuid; i int; j int; k int;
BEGIN
  i := 100 + (SELECT count(*) FROM nutrition_plans WHERE order_id IS NULL);
  FOR p IN SELECT * FROM jsonb_array_elements(d) LOOP
    SELECT id INTO v_plan FROM nutrition_plans WHERE order_id IS NULL AND lower(trim(name)) = lower(trim(p->>'name'));
    IF v_plan IS NULL THEN
      INSERT INTO nutrition_plans (name, notes, position) VALUES (p->>'name', p->>'notes', i) RETURNING id INTO v_plan;
    ELSE
      -- تحديث: الوجبات تُستبدل بالنسخة الحالية (الحذف يشمل عناصرها)
      DELETE FROM plan_meals WHERE plan_id = v_plan;
      UPDATE nutrition_plans SET notes = p->>'notes', updated_at = now() WHERE id = v_plan;
    END IF;
    i := i + 1; j := 0;
    FOR m IN SELECT * FROM jsonb_array_elements(p->'meals') LOOP
      INSERT INTO plan_meals (plan_id, kind, title, method, position) VALUES (v_plan, m->>'kind', m->>'title', nullif(m->>'method', ''), j) RETURNING id INTO v_meal;
      k := 0;
      FOR it IN SELECT * FROM jsonb_array_elements(m->'items') LOOP
        INSERT INTO plan_items (meal_id, food, portion, protein, carbs, fat, position)
        VALUES (v_meal, it->>'food', nullif(it->>'portion', ''), (it->>'protein')::numeric, (it->>'carbs')::numeric, (it->>'fat')::numeric, k);
        k := k + 1;
      END LOOP;
      j := j + 1;
    END LOOP;
  END LOOP;
END $do$;

SELECT p.name, round(sum(i.protein*4 + i.carbs*4 + i.fat*9)) AS kcal, count(DISTINCT m.id) AS meals
  FROM nutrition_plans p JOIN plan_meals m ON m.plan_id = p.id JOIN plan_items i ON i.meal_id = m.id
 WHERE p.order_id IS NULL AND p.name IN ('قالب مضادات الأكسدة') GROUP BY p.name, p.position ORDER BY p.position;
COMMIT;
