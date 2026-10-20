// بيانات تجريبية للتطوير فقط، موسومة is_demo = true. يرفض العمل على قاعدة غير محلية.
// الاستخدام: npm run db:seed-demo   ثم احذفها بـ: node scripts/purge-demo.mjs
import pg from "pg";
import { loadEnv } from "./env.mjs";

loadEnv();
const url = process.env.DATABASE_URL_OWNER ?? "";
if (!/@(localhost|127\.0\.0\.1)[:/]/.test(url)) throw new Error("البيانات التجريبية مسموحة على قاعدة محلية فقط.");
const db = new pg.Client({ connectionString: url });
await db.connect();
await db.query("BEGIN");
await db.query(`INSERT INTO "user" (id, name, email, "emailVerified", role) VALUES
  ('demo-client', 'عميل تجريبي', 'demo-client@example.test', true, 'client') ON CONFLICT DO NOTHING`);
const { rows: [p] } = await db.query(`
  INSERT INTO products (slug, category, name, audience, items, status, is_demo, sort)
  VALUES ('demo-product', 'files', 'منتج تجريبي (للتطوير فقط)', 'لاختبار رحلة الشراء — ليس منتجاً حقيقياً',
          '[{"text":"عنصر تجريبي","included":true}]', 'published', true, 99)
  ON CONFLICT (slug) DO UPDATE SET is_demo = true RETURNING id`);
await db.query(`INSERT INTO product_offers (product_id, sku, label, months, price_halalas)
  VALUES ($1, 'demo1', 'دفعة واحدة', 0, 100) ON CONFLICT (sku) DO NOTHING`, [p.id]);
await db.query("SELECT set_config('app.user_id', 'demo-client', true)");
for (let i = 0; i < 3; i++) {
  await db.query(`SELECT app.create_order('demo1', $1, false, 'عميل تجريبي', '+966500000000', '{}'::jsonb, '{}'::jsonb, false, 'لا، أفضّل الخصوصية', '')`, [`demo-order-key-000${i}`]);
}
await db.query("UPDATE orders SET is_demo = true WHERE user_id = 'demo-client'");
await db.query("COMMIT");
console.log("✓ بيانات تجريبية: منتج واحد و3 طلبات (is_demo)");
await db.end();
