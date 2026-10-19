// «ملاحظات مهمة للأداء» لكل تمرين في المكتبة (غير التأهيلي: التأهيلي له ملاحظات سلامته الخاصة ومراجعه).
// لكل تمرين ملاحظاته الخاصة (وضعية، حركة، أخطاء شائعة، تنبيهات)، وليست تعليمات علاجية.
// تُضاف في آخر «تعليمات الأداء» التي يراها المتدرب، ولا تتكرر عند إعادة التشغيل.
import { readFileSync, writeFileSync } from "node:fs";
import { loadExercises } from "./exercises-sql.mjs";

export const MARK = "ملاحظات مهمة:";

// ملاحظات كل تمرين مكتوبة باسمه في exercise-notes-data-*.txt بصيغة «الاسم :: نقطة | نقطة | نقطة»
const SPECIFIC = new Map();
for (const f of ["exercise-notes-data-1.txt", "exercise-notes-data-2.txt"]) {
  for (const line of readFileSync(new URL(`./${f}`, import.meta.url), "utf8").split("\n")) {
    const [name, rest] = line.split(" :: ");
    if (name && rest) SPECIFIC.set(name.trim().toLowerCase(), rest.split(" | ").map((x) => x.trim()).filter(Boolean));
  }
}
export function notesFor(e) {
  if (e.rehab_category) return null; // التأهيلي له ملاحظات سلامته
  const pts = SPECIFIC.get(e.name.trim().toLowerCase());
  if (!pts) return null;
  return `${MARK}\n${pts.map((c) => `• ${c}`).join("\n")}`;
}

export function notesRows() {
  const rows = [], missing = [];
  for (const e of loadExercises()) {
    const n = notesFor(e);
    if (n) rows.push({ name: e.name, notes: n }); else if (!e.rehab_category) missing.push(e.name);
  }
  return { rows, missing };
}

/** تحديث آمن للتكرار: يضيف الملاحظات لآخر تعليمات الأداء إن لم تكن موجودة بعد */
export function notesSql(rows = notesRows().rows) {
  const json = JSON.stringify(rows);
  if (json.includes("$nt$")) throw new Error("notes تحتوي $nt$");
  return `UPDATE exercises e
   SET instructions = CASE WHEN coalesce(trim(e.instructions), '') = '' THEN x.notes ELSE e.instructions || E'\\n\\n' || x.notes END
  FROM jsonb_to_recordset($nt$${json}$nt$::jsonb) AS x(name text, notes text)
 WHERE lower(trim(e.name)) = lower(trim(x.name)) AND coalesce(e.instructions, '') NOT LIKE '%${MARK}%';
`;
}

if (process.argv[1]?.endsWith("exercise-notes.mjs")) {
  const { rows, missing } = notesRows();
  const sql = `-- ملاحظات مهمة لأداء كل تمرين في المكتبة (تُضاف لتعليمات الأداء التي يراها المتدرب). بيانات فقط، آمنة للتكرار.
-- مكتوبة لكل تمرين باسمه. التمارين التأهيلية مستثناة (لها ملاحظات سلامتها).
BEGIN;
${notesSql(rows)}COMMIT;
`;
  writeFileSync(new URL("../db/updates/2026-10-01-exercise-notes.sql", import.meta.url), sql);
  console.log(`rows=${rows.length} missing=${missing.length} bytes=${sql.length}`, missing.join("; "));
}
