// يولّد ملف تحديث Neon لقاعدة الأكل: migration 012 + أصناف USDA (إن وُلّد db/seed/foods.json).
import { readFileSync, writeFileSync } from "node:fs";
import { foodsSql } from "./foods-sql.mjs";

const mig = readFileSync("db/migrations/012_foods.sql", "utf8");
const data = foodsSql();
writeFileSync("db/updates/2026-09-28-foods.sql", [
  "-- قاعدة الأكل بالغرامات (المتدرب يختار الصنف ويكتب الغرامات فتُحسب الماكروز) + بحث FatSecret الاختياري.",
  "-- يُشغَّل مرة واحدة في Neon ← SQL Editor في محرر فاضي، بعد ملف nutrition. لا يغيّر أي بيانات موجودة.",
  "BEGIN;", mig, data || "-- (أصناف USDA تُضاف بملف منفصل بعد توليدها)",
  "INSERT INTO schema_migrations (name) VALUES ('012_foods.sql');", "COMMIT;", ""].join("\n"));
console.log(`✓ db/updates/2026-09-28-foods.sql${data ? " (مع الأصناف)" : " (بدون أصناف)"}`);
