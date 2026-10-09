// يمنح دور المدربة لحساب موجود (سجّلي الدخول مرة واحدة بالبريد أولاً):
//   npm run make-coach -- coach@example.com
import pg from "pg";
import { loadEnv } from "./env.mjs";

loadEnv();
const email = process.argv[2]?.trim().toLowerCase();
if (!email) throw new Error("اكتبي البريد: npm run make-coach -- email@example.com");
const client = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
await client.connect();
const r = await client.query(`UPDATE "user" SET role = 'coach' WHERE lower(email) = $1 RETURNING id`, [email]);
console.log(r.rowCount ? `✓ ${email} أصبح حساب مدربة` : `✗ لا يوجد حساب بهذا البريد. سجّلي الدخول مرة أولاً من /login`);
await client.end();
