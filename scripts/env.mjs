// تحميل بسيط لملف .env.local ثم .env (بدون مكتبات إضافية). لا يطغى على متغيرات البيئة الموجودة.
import { existsSync, readFileSync } from "node:fs";

export function loadEnv() {
  for (const file of [process.env.ENV_FILE, ".env.local", ".env"].filter(Boolean)) {
    if (!existsSync(file)) continue;
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (!m || process.env[m[1]] !== undefined) continue;
      process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  }
}
