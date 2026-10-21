// ينسخ منطق الموقع الصافي (بدون واجهة ولا خادم) إلى التطبيق حتى يعمل بدون إنترنت وبنفس النتائج تماماً.
// الاختبار tests/shared.test.mts يفشل إذا اختلفت النسخة عن الموقع: شغّل هذا السكربت بعد أي تعديل هناك.
//   node scripts/sync-shared.mjs
import { readFileSync, writeFileSync } from "node:fs";

export const SHARED = [
  ["../../src/lib/calories.ts", "../src/shared/calories.ts"],
  ["../../src/lib/pain.ts", "../src/shared/pain.ts"],
];
export const header = (from) => `// ⚠️ منسوخ تلقائياً من ${from.replace("../../", "")} في الموقع (node scripts/sync-shared.mjs). لا تعدّله هنا.\n`;

if (import.meta.url === `file://${process.argv[1]}`) {
  for (const [from, to] of SHARED) {
    writeFileSync(new URL(to, import.meta.url), header(from) + readFileSync(new URL(from, import.meta.url), "utf8"));
    console.log("synced", to);
  }
}
