// يجهّز قاعدة اختبار منفصلة (nav_e2e) من الصفر ثم يبني الموقع ويشغّله على المنفذ 3100.
// لا يلمس قاعدة التطوير أو الإنتاج.
import { execSync, spawn } from "node:child_process";
import { rmSync } from "node:fs";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const APP = process.env.E2E_DATABASE_URL ?? "postgres://nav_app:nav_app_dev@localhost:5432/nav_e2e";
if (!/localhost|127\.0\.0\.1/.test(OWNER)) throw new Error("E2E يعمل على قاعدة محلية فقط");

const c = new pg.Client({ connectionString: OWNER });
await c.connect();
await c.query("DROP SCHEMA IF EXISTS app CASCADE; DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
await c.end();

const env = {
  ...process.env,
  ENV_FILE: "/dev/null",
  DATABASE_URL_OWNER: OWNER,
  DATABASE_URL: APP,
  BETTER_AUTH_SECRET: "e2e-only-secret-0123456789abcdefghijklmnop",
  BETTER_AUTH_URL: "http://localhost:3100",
  NEXT_PUBLIC_SITE_URL: "http://localhost:3100",
  STORAGE_DRIVER: "local",
  LOCAL_UPLOAD_DIR: ".data/e2e-uploads",
  COACH_NOTIFY_EMAIL: "coach-notify@e2e.test",
  RESEND_API_KEY: "",
  MAIL_FROM: "",
  E2E_MAILBOX: "1",
  WORKOUT_VISION_MOCK: "1",
  CRON_SECRET: "e2e-cron-secret-0123456789",
  NEXT_DIST_DIR: ".next-e2e",
};
rmSync(".data/e2e-uploads", { recursive: true, force: true });
execSync("node scripts/migrate.mjs", { env, stdio: "inherit" });
execSync("node scripts/seed.mjs", { env, stdio: "inherit" });
execSync("npx next build", { env, stdio: "inherit" });
const srv = spawn("npx", ["next", "start", "-p", "3100"], { env, stdio: "inherit" });
process.on("SIGTERM", () => srv.kill("SIGTERM"));
process.on("SIGINT", () => srv.kill("SIGINT"));
