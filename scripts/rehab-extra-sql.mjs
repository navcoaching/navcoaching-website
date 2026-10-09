// يولّد ملف Neon للتمارين التأهيلية الإضافية (db/seed/rehab-extra.json). بيانات فقط، آمن للتكرار (لا يستبدل تمريناً موجوداً).
import { writeFileSync } from "node:fs";
import { exercisesSql, loadRehabExtra } from "./exercises-sql.mjs";

const rows = loadRehabExtra();
const sql = `-- تمارين تأهيلية وعلاجية إضافية (ركبة، أسفل الظهر، مرفق التنس) بمراجعها، وحالتها «تحتاج مراجعة أخصائي».
-- بيانات فقط: آمن للتكرار ولا يستبدل تمريناً موجوداً. المتدرب لا يرى التصنيف التأهيلي.
BEGIN;
${exercisesSql(rows, "exercises")}
COMMIT;
`;
writeFileSync(new URL("../db/updates/2026-09-30-rehab-exercises.sql", import.meta.url), sql);
console.log(`rows=${rows.length} bytes=${sql.length}`);
