// استعادة نسخة من scripts/backup.mjs إلى قاعدة بيانات **فارغة** ومجلد ملفات، ثم التحقق أنها كاملة
// (عدد صفوف كل جدول وبصمة كل ملف تطابق ما سُجّل وقت النسخ).
// الاستخدام: RESTORE_DATABASE_URL=postgres://neondb_owner:...@host/nav_restore BACKUP_PASSPHRASE=... node scripts/restore.mjs <ملف.enc> [مجلد الملفات]
// لا يكتب أبداً على قاعدة فيها جداول، فلا يمكن أن يمسح الإنتاج بالخطأ.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import pg from "pg";

const [file, filesOut = ".data/restored-uploads"] = process.argv.slice(2);
const DB = process.env.RESTORE_DATABASE_URL;
if (!file || !DB) throw new Error("الاستخدام: RESTORE_DATABASE_URL=... BACKUP_PASSPHRASE=... node scripts/restore.mjs <ملف.enc> [مجلد الملفات]");

const work = mkdtempSync(path.join(tmpdir(), "nav-restore-"));
const t0 = Date.now();
try {
  execFileSync("openssl", ["enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-in", file, "-out", path.join(work, "b.tar.gz"), "-pass", "env:BACKUP_PASSPHRASE"]);
  execFileSync("tar", ["-xzf", path.join(work, "b.tar.gz"), "-C", work]);
  const manifest = JSON.parse(readFileSync(path.join(work, "manifest.json"), "utf8"));

  const c = new pg.Client({ connectionString: DB, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
  await c.connect();
  const existing = (await c.query("SELECT count(*)::int AS n FROM pg_tables WHERE schemaname = 'public'")).rows[0].n;
  if (existing > 0) throw new Error(`القاعدة الهدف فيها ${existing} جدول. الاستعادة تكون على قاعدة فارغة فقط.`);
  execFileSync("pg_restore", ["--no-owner", "--exit-on-error", "--single-transaction", "--dbname", DB, path.join(work, "db.dump")], { stdio: "inherit" });

  const bad = [];
  for (const [t, n] of Object.entries(manifest.rows)) {
    const got = (await c.query(`SELECT count(*)::int AS n FROM public."${t.replace(/"/g, '""')}"`)).rows[0].n;
    if (got !== n) bad.push(`${t}: ${got} بدل ${n}`);
  }
  await c.end();

  for (const [key, hash] of Object.entries(manifest.files)) {
    if (createHash("sha256").update(readFileSync(path.join(work, "files", key))).digest("hex") !== hash) bad.push(`ملف تالف: ${key}`);
  }
  if (bad.length) throw new Error(`الاستعادة غير مطابقة:\n${bad.join("\n")}`);
  cpSync(path.join(work, "files"), path.resolve(filesOut), { recursive: true });

  const rows = Object.values(manifest.rows).reduce((a, b) => a + b, 0);
  console.log(`✓ استعادة مطابقة لنسخة ${manifest.created_at}: ${Object.keys(manifest.rows).length} جدول، ${rows} صف، ${Object.keys(manifest.files).length} ملف ← ${filesOut} (${((Date.now() - t0) / 1000).toFixed(1)} ثانية)`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
