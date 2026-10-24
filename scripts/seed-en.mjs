// المحتوى الإنجليزي الأولي (db/seed/source/en): يُكتب في i18n.en فقط للصفوف التي لا ترجمة لها بعد،
// فلا يطغى على ما عدّلته المدربة من لوحة الإدارة. يُستدعى من seed.mjs، ويولّد SQL الإنتاج عبر build-i18n-sql.mjs.
import { readFile } from "node:fs/promises";

export async function loadEn() {
  const read = async (f) => JSON.parse(await readFile(new URL(`../db/seed/source/en/${f}.json`, import.meta.url), "utf8"));
  return { products: await read("products"), faqs: await read("faqs"), policies: await read("policies"), settings: await read("settings") };
}

/** قائمة [sql, params] تُنفَّذ بالترتيب */
export async function enStatements() {
  const en = await loadEn();
  const out = [];
  const set = (table, where, obj, p) => out.push([`UPDATE ${table} SET i18n = jsonb_set(i18n, '{en}', $1::jsonb) WHERE ${where} AND NOT (i18n ? 'en')`, [JSON.stringify(obj), ...p]]);
  for (const [slug, v] of Object.entries(en.products)) {
    const row = { name: v.name, audience: v.audience, note: v.note ?? null, delivery: v.delivery ?? null, requirements: v.requirements ?? null, policy_note: v.policy_note ?? null, items: v.items.map((text) => ({ text })) };
    set("products", "slug = $2", row, [slug]);
  }
  for (const f of en.faqs) set("faqs", "question = $2", { question: f.question, answer: f.answer }, [f.q]);
  for (const [slug, v] of Object.entries(en.policies)) set("policies", "slug = $2", v, [slug]);
  for (const [key, v] of Object.entries(en.settings)) set("site_settings", "key = $2", v, [key]);
  return out;
}
