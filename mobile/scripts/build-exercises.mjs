// يولّد مكتبة التمارين المضمّنة في التطبيق من بيانات الموقع (db/seed/exercises.json): المعتمد فقط.
// التطبيق يعمل بدون إنترنت وبدون حساب، فالمكتبة جزء من التطبيق نفسه. بدائل الكوتش لا تُضمَّن:
// ميزة «ناف برو» تُجلب من الموقع للمشترك (/api/mobile/v1/coach-alts). شغّله بعد تحديث المكتبة:
//   node scripts/build-exercises.mjs
import { readFileSync, writeFileSync } from "node:fs";

const src = JSON.parse(readFileSync(new URL("../../db/seed/exercises.json", import.meta.url), "utf8"));
const slug = (s) => s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const ar = (s) => (s && s.includes(" / ") ? s.split(" / ").slice(1).join(" / ").trim() : s ?? null);

const approved = src.filter((x) => x.status === "approved");
const ids = new Map(approved.map((x) => [x.name.trim().toLowerCase(), slug(x.name)]));
if (new Set(ids.values()).size !== ids.size) throw new Error("تكرار في معرّفات التمارين");

const out = approved
  .map((x) => ({
    id: slug(x.name),
    name: x.name.trim(),
    muscle: ar(x.primary_muscle),
    secondary: (x.secondary_muscles ?? []).map(ar),
    kind: x.kind ?? null,
    equipment: x.equipment ?? null,
    place: x.place ?? null,
    level: x.level ?? null,
    video: x.video_url ?? null,
    instructions: x.instructions ?? null,
  }))
  .sort((a, b) => a.muscle.localeCompare(b.muscle, "ar") || a.name.localeCompare(b.name));

writeFileSync(new URL("../src/data/exercises.json", import.meta.url), JSON.stringify(out) + "\n");
console.log(`exercises: ${out.length}`);
