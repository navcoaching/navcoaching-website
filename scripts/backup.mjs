// نسخة احتياطية كاملة مشفّرة: قاعدة البيانات (pg_dump) + كل الملفات الخاصة (Netlify Blobs أو المجلد المحلي).
// الناتج ملف واحد مشفّر AES-256 (openssl، مفتاح مشتق PBKDF2) لا يُفتح إلا بـ BACKUP_PASSPHRASE.
// الاستخدام: node scripts/backup.mjs [مجلد الإخراج]   — يعمل يومياً من .github/workflows/backup.yml
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import pg from "pg";
import { loadEnv } from "./env.mjs";

loadEnv();
const DB = process.env.BACKUP_DATABASE_URL || process.env.DATABASE_URL_OWNER;
const PASS = process.env.BACKUP_PASSPHRASE ?? "";
if (!DB) throw new Error("BACKUP_DATABASE_URL (أو DATABASE_URL_OWNER) غير معرّف");
if (PASS.length < 24) throw new Error("BACKUP_PASSPHRASE لازم 24 حرفاً أو أكثر");

const out = path.resolve(process.argv[2] ?? "backups");
const work = mkdtempSync(path.join(tmpdir(), "nav-backup-"));
const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-");
try {
  // 1) قاعدة البيانات: صيغة custom (مضغوطة، تُستعاد بـ pg_restore)
  execFileSync("pg_dump", ["--format=custom", "--no-owner", "--file", path.join(work, "db.dump"), DB], { stdio: "inherit" });

  // 2) عدد الصفوف لكل جدول: يُقارن بعد الاستعادة للتأكد أنها كاملة
  const c = new pg.Client({ connectionString: DB, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
  await c.connect();
  const tables = (await c.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1")).rows.map((r) => r.tablename);
  const rows = {};
  for (const t of tables) rows[t] = (await c.query(`SELECT count(*)::int AS n FROM public."${t.replace(/"/g, '""')}"`)).rows[0].n;
  await c.end();

  // 3) الملفات الخاصة
  const files = path.join(work, "files");
  mkdirSync(files);
  const hashes = {};
  const save = (key, buf) => {
    const p = path.resolve(files, key);
    if (!p.startsWith(files + path.sep)) throw new Error(`مفتاح غير صالح: ${key}`);
    mkdirSync(path.dirname(p), { recursive: true });
    writeFileSync(p, buf);
    hashes[key] = createHash("sha256").update(buf).digest("hex");
  };
  if (process.env.STORAGE_DRIVER === "netlify") {
    const { getStore } = await import("@netlify/blobs");
    const store = getStore({ name: "private-files", siteID: process.env.NETLIFY_SITE_ID, token: process.env.NETLIFY_AUTH_TOKEN, consistency: "strong" });
    const { blobs } = await store.list();
    for (const b of blobs) {
      const ab = await store.get(b.key, { type: "arrayBuffer" });
      if (ab) save(b.key, Buffer.from(ab));
    }
  } else {
    const root = path.resolve(process.env.LOCAL_UPLOAD_DIR ?? ".data/uploads");
    const walk = (d) => { for (const f of readdirSync(d)) { const p = path.join(d, f); statSync(p).isDirectory() ? walk(p) : save(path.relative(root, p), readFileSync(p)); } };
    try { walk(root); } catch (e) { if (e.code !== "ENOENT") throw e; }
  }

  writeFileSync(path.join(work, "manifest.json"), JSON.stringify({ created_at: new Date().toISOString(), rows, files: hashes }, null, 1));

  // 4) أرشيف واحد مشفّر
  mkdirSync(out, { recursive: true });
  const file = path.join(out, `nav-backup-${stamp}.tar.gz.enc`);
  execFileSync("tar", ["-czf", path.join(work, "b.tar.gz"), "-C", work, "db.dump", "files", "manifest.json"]);
  execFileSync("openssl", ["enc", "-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-salt", "-in", path.join(work, "b.tar.gz"), "-out", file, "-pass", "env:BACKUP_PASSPHRASE"]);
  const total = Object.values(rows).reduce((a, b) => a + b, 0);
  console.log(`✓ ${file} (${(statSync(file).size / 1e6).toFixed(1)} MB): ${tables.length} جدول، ${total} صف، ${Object.keys(hashes).length} ملف`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
