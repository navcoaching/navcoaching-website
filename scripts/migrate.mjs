// يطبّق ملفات db/migrations بالترتيب مرة واحدة لكل ملف. يُشغّل بحساب المالك فقط.
import { readdir, readFile } from "node:fs/promises";
import pg from "pg";
import { loadEnv } from "./env.mjs";

loadEnv();
const url = process.env.DATABASE_URL_OWNER;
if (!url) throw new Error("DATABASE_URL_OWNER غير معرّف");

const client = new pg.Client({ connectionString: url, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
await client.connect();
await client.query("CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())");
const done = new Set((await client.query("SELECT name FROM schema_migrations")).rows.map((r) => r.name));
const files = (await readdir(new URL("../db/migrations/", import.meta.url))).filter((f) => f.endsWith(".sql")).sort();

for (const file of files) {
  if (done.has(file)) continue;
  const sql = await readFile(new URL(`../db/migrations/${file}`, import.meta.url), "utf8");
  try {
    await client.query("BEGIN");
    await client.query(sql);
    await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [file]);
    await client.query("COMMIT");
    console.log("✓", file);
  } catch (err) {
    await client.query("ROLLBACK");
    console.error("✗", file, err.message);
    process.exitCode = 1;
    break;
  }
}
await client.end();
