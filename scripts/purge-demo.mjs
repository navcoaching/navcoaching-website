// يحذف كل البيانات الموسومة is_demo (منتجات وطلبات تجريبية) — شغّليه قبل الإطلاق للتأكد.
import pg from "pg";
import { loadEnv } from "./env.mjs";

loadEnv();
const db = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
await db.connect();
await db.query("BEGIN");
// السجل للإضافة فقط؛ يُسمح بالحذف هنا للبيانات التجريبية فقط داخل هذه المعاملة
await db.query("ALTER TABLE order_events DISABLE TRIGGER order_events_append_only");
const o = await db.query("DELETE FROM orders WHERE is_demo RETURNING order_no");
await db.query("ALTER TABLE order_events ENABLE TRIGGER order_events_append_only");
const p = await db.query("DELETE FROM products WHERE is_demo AND NOT EXISTS (SELECT 1 FROM orders WHERE orders.product_id = products.id) RETURNING slug");
await db.query(`DELETE FROM "user" WHERE id = 'demo-client' AND NOT EXISTS (SELECT 1 FROM orders WHERE user_id = 'demo-client')`);
await db.query("COMMIT");
console.log(`✓ حُذف ${o.rowCount} طلب تجريبي و${p.rowCount} منتج تجريبي`);
await db.end();
