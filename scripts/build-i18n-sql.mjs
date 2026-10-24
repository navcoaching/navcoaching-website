// يولّد db/updates/2026-10-24-i18n.sql للإنتاج: عمود i18n + المحتوى الإنجليزي الأولي (لا يطغى على ترجمة موجودة).
//   node scripts/build-i18n-sql.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { enStatements } from "./seed-en.mjs";

const lit = (v) => `'${String(v).replace(/'/g, "''")}'`;
const body = (await enStatements()).map(([sql, params]) => sql.replace(/\$(\d+)(::jsonb)?/g, (_, i, cast) => lit(params[i - 1]) + (cast ?? ""))).join(";\n") + ";";
const schema = readFileSync(new URL("../db/migrations/047_i18n.sql", import.meta.url), "utf8");
const out = `-- النسخة الإنجليزية: عمود i18n والمحتوى الإنجليزي الأولي. يُشغَّل مرة واحدة؛ إعادة التشغيل تُرفض تلقائياً بلا ضرر.
BEGIN;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = '047_i18n.sql') THEN
    RAISE EXCEPTION 'هذا الملف مطبّق من قبل، لا حاجة لتشغيله مرة ثانية. اضغطي ROLLBACK.';
  END IF;
END $g$;
${schema}
-- المحتوى الإنجليزي الأولي (يُكتب فقط حيث لا ترجمة بعد)
${body}
INSERT INTO schema_migrations (name) VALUES ('047_i18n.sql');
COMMIT;
`;
writeFileSync(new URL("../db/updates/2026-10-24-i18n.sql", import.meta.url), out);
console.log("✓ db/updates/2026-10-24-i18n.sql");
