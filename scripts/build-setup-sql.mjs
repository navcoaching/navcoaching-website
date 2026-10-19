// يولّد db/setup.sql: ملف واحد يُلصق في محرر SQL لدى مزود قاعدة البيانات (Neon/Supabase)
// ويحتوي: الجداول + الصلاحيات + المحتوى الحقيقي المستورد. يُعاد توليده عند تغيير الترحيلات أو المحتوى:
//   node scripts/build-setup-sql.mjs   (يحتاج Postgres محلياً)
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import pg from "pg";

const ADMIN = process.env.SETUP_ADMIN_URL ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/postgres";
const TMP = "nav_setup_tmp";
const TMP_URL = ADMIN.replace(/\/[^/]+$/, `/${TMP}`);

const admin = new pg.Client({ connectionString: ADMIN });
await admin.connect();
await admin.query(`DROP DATABASE IF EXISTS ${TMP}`);
await admin.query(`CREATE DATABASE ${TMP}`);
await admin.end();

const env = { ...process.env, ENV_FILE: "/dev/null", DATABASE_URL_OWNER: TMP_URL };
execFileSync("node", ["scripts/migrate.mjs"], { env, stdio: "inherit" });
execFileSync("node", ["scripts/seed.mjs"], { env, stdio: "inherit" });

const tables = ["products", "product_offers", "site_settings", "faqs", "policies", "reviews", "exercises", "exercise_alternatives", "foods"];
const data = execFileSync("pg_dump", ["--data-only", "--inserts", "--on-conflict-do-nothing", "--no-owner", "--no-privileges", ...tables.flatMap((t) => ["-t", `public.${t}`]), TMP_URL], { encoding: "utf8" })
  // نحذف أسطر الإعداد والتعليقات فقط؛ قيم النصوص قد تمتد على عدة أسطر فلا نقصّها
  .split("\n").filter((l) => !/^(SET |SELECT pg_catalog\.set_config|--( |$)|\\)/.test(l) && l !== "--").join("\n").trim();

const files = readdirSync("db/migrations").filter((f) => f.endsWith(".sql")).sort();
const out = [
  "-- =====================================================================",
  "-- Nav Coaching — ملف الإعداد الكامل (يُنفَّذ مرة واحدة فقط على قاعدة فارغة)",
  "-- مولَّد تلقائياً بـ scripts/build-setup-sql.mjs — لا تعدّليه يدوياً.",
  "-- =====================================================================",
  "BEGIN;",
  "CREATE TABLE schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());",
  ...files.flatMap((f) => [`\n-- ---------- ${f} ----------`, readFileSync(`db/migrations/${f}`, "utf8"), `INSERT INTO schema_migrations (name) VALUES ('${f}');`]),
  "\n-- ---------- المحتوى المستورد من الموقع الحالي ----------",
  data,
  "COMMIT;",
  "",
].join("\n");
writeFileSync("db/setup.sql", out);

const a2 = new pg.Client({ connectionString: ADMIN });
await a2.connect();
await a2.query(`DROP DATABASE ${TMP}`);
await a2.end();
console.log(`✓ db/setup.sql (${(out.length / 1024).toFixed(0)} KB)`);
