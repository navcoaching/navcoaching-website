// يولّد SQL استيراد مكتبة التمارين من db/seed/exercises.json (مصدرها ورقة «مكتبة التمارين» في قالب ملف التدريب).
// آمن للتكرار: لا يستبدل تمريناً موجوداً (حتى لا تضيع تعديلات المدربة)، والبدائل تُضاف فقط لتمرين بلا بدائل.
import { readFileSync } from "node:fs";

export const loadExercises = () => JSON.parse(readFileSync(new URL("../db/seed/exercises.json", import.meta.url), "utf8"));
const literal = (rows) => {
  const json = JSON.stringify(rows);
  if (json.includes("$ex$")) throw new Error("exercises.json يحتوي $ex$");
  return `$ex$${json}$ex$::jsonb`;
};

/** SQL كامل (التمارين ثم البدائل)، أو جزء منه: part = "exercises" لدفعة صفوف، أو "alternatives" */
export function exercisesSql(rows = loadExercises(), part = "all") {
  const data = literal(part === "alternatives" ? rows.filter((r) => r.alternatives?.length).map((r) => ({ name: r.name, alternatives: r.alternatives })) : rows);
  const ex = `INSERT INTO exercises (name, primary_muscle, secondary_muscles, pattern, kind, equipment, level, place, video_url,
  instructions, notes, source, source_name, source_url, rehab_category, status, sub_pattern, anatomical_action, movement_subcategory)
SELECT trim(x.name), x.primary_muscle, coalesce(x.secondary_muscles, '{}'), x.pattern, x.kind, x.equipment, x.level, x.place, x.video_url,
  x.instructions, x.notes, x.source, x.source_name, x.source_url, x.rehab_category, x.status, x.sub_pattern, x.anatomical_action, x.movement_subcategory
  FROM jsonb_to_recordset(${data}) AS x(name text, primary_muscle text, secondary_muscles text[], pattern text, kind text, equipment text,
    level text, place text, video_url text, instructions text, notes text, source text, source_name text, source_url text, rehab_category text, status text,
    sub_pattern text, anatomical_action text, movement_subcategory text)
ON CONFLICT ((lower(trim(name)))) DO NOTHING;
`;
  const alt = `INSERT INTO exercise_alternatives (exercise_id, alt_id, position)
SELECT e.id, a.id, (t.ord - 1)::int
  FROM jsonb_to_recordset(${data}) AS x(name text, alternatives text[])
  JOIN exercises e ON lower(trim(e.name)) = lower(trim(x.name))
  CROSS JOIN LATERAL unnest(coalesce(x.alternatives, '{}')) WITH ORDINALITY AS t(alt, ord)
  JOIN exercises a ON lower(trim(a.name)) = lower(trim(t.alt)) AND a.id <> e.id
 WHERE NOT EXISTS (SELECT 1 FROM exercise_alternatives z WHERE z.exercise_id = e.id)
ON CONFLICT DO NOTHING;
`;
  if (part === "taxonomy") {
    // يملأ التصنيف التفصيلي للتمارين الموجودة (الحقل الفارغ فقط، فلا يستبدل تعديلات المدربة)
    const t = literal(rows.map((r) => ({ name: r.name, sub_pattern: r.sub_pattern ?? null, anatomical_action: r.anatomical_action ?? null, movement_subcategory: r.movement_subcategory ?? null })));
    return `UPDATE exercises e SET
    sub_pattern = coalesce(e.sub_pattern, x.sub_pattern),
    anatomical_action = coalesce(e.anatomical_action, x.anatomical_action),
    movement_subcategory = coalesce(e.movement_subcategory, x.movement_subcategory)
  FROM jsonb_to_recordset(${t}) AS x(name text, sub_pattern text, anatomical_action text, movement_subcategory text)
 WHERE lower(trim(e.name)) = lower(trim(x.name));
`;
  }
  return part === "exercises" ? ex : part === "alternatives" ? alt : ex + "\n" + alt;
}
