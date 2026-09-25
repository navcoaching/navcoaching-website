import "server-only";
import { Pool, type PoolClient } from "pg";

/**
 * اتصال واحد بقاعدة البيانات بدور `nav_app` (ليس مالك الجداول، ولا يتجاوز RLS).
 * كل استعلام يخص مستخدماً يمر عبر withUser حتى تطبّق قاعدة البيانات سياسات الصلاحيات
 * بناءً على هوية الجلسة، لا على ما تعرضه الواجهة.
 */
const globalForPool = globalThis as unknown as { __navPool?: Pool };

export const pool =
  globalForPool.__navPool ??
  new Pool({
    connectionString: process.env.DATABASE_URL,
    max: Number(process.env.DATABASE_POOL_MAX ?? 5),
    ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined,
  });

if (process.env.NODE_ENV !== "production") globalForPool.__navPool = pool;

export type Tx = PoolClient;

/** ينفّذ fn داخل معاملة مرتبطة بهوية المستخدم (أو زائر عند userId=null). */
export async function withUser<T>(userId: string | null, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [userId ?? ""]);
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

export const withAnon = <T>(fn: (tx: Tx) => Promise<T>) => withUser(null, fn);

/** يحوّل أخطاء قاعدة البيانات المقصودة (RAISE ... USING ERRCODE='P0001') إلى رسالة عربية آمنة للعرض. */
export function dbErrorMessage(err: unknown): string | null {
  const e = err as { code?: string; message?: string };
  if (e?.code === "P0001" && e.message) return e.message;
  if (e?.code === "42501") return "لا تملك صلاحية لهذا الإجراء.";
  return null;
}
