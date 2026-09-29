import "server-only";
import { Pool, type PoolClient, type QueryResult } from "pg";

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
  if (userId === null) return withAnon(fn);
  const client = await pool.connect();
  let broken = false;
  try {
    // رحلة واحدة بدل اثنتين (كل رحلة إلى Neon تكلّف زمن الشبكة بالكامل). escapeLiteral يحمي من الحقن مثل المعاملات
    await client.query(`BEGIN; SELECT set_config('app.user_id', ${client.escapeLiteral(userId)}, true)`);
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    // إذا تعذّر التراجع يُتلف الاتصال بدل إرجاعه للمجموعة، حتى لا تنتقل حالته لطلب آخر
    await client.query("ROLLBACK").catch(() => { broken = true; });
    throw err;
  } finally {
    client.release(broken);
  }
}

/**
 * قراءات الزائر: بدون معاملة ولا ضبط هوية (رحلة واحدة لقاعدة البيانات بدل أربع).
 * الهوية فارغة تلقائياً لأن withUser يضبطها على مستوى المعاملة فقط (is_local)،
 * فلا تبقى على الاتصال بعد انتهاء المعاملة، وسياسات RLS تعامل الطلب كزائر.
 */
export async function withAnon<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    return await fn(client);
  } finally {
    client.release();
  }
}

/**
 * يرسل عدة استعلامات مستقلة في رحلة شبكة واحدة ويرجع نتيجة كل واحد بترتيبه (نفس أنواع البيانات المعتادة).
 * اتصال المعاملة الواحدة يعالج استعلاماً واحداً في كل رحلة، فكل استعلام منفصل يكلّف زمن الشبكة كاملاً إلى Neon.
 * لا تدعم معاملات ($1): مرّر القيم عبر lit() وlitList()، ولا تضع قيمة من المستخدم في النص مباشرة.
 */
export async function batch(tx: Tx, sqls: string[]): Promise<QueryResult[]> {
  const r = (await tx.query(sqls.map((q) => q.trim().replace(/;+$/, "")).join(";\n"))) as unknown as QueryResult | QueryResult[];
  return Array.isArray(r) ? r : [r];
}
/** قيمة نصية آمنة داخل batch */
export const lit = (tx: Tx, v: unknown) => tx.escapeLiteral(String(v));
/** مصفوفة قيم آمنة داخل batch، مثل litList(tx, ids, "uuid") ← ARRAY['..','..']::uuid[] */
export const litList = (tx: Tx, vs: unknown[], type: "uuid" | "text") => `ARRAY[${vs.map((v) => tx.escapeLiteral(String(v))).join(",")}]::${type}[]`;

/** يحوّل أخطاء قاعدة البيانات المقصودة (RAISE ... USING ERRCODE='P0001') إلى رسالة عربية آمنة للعرض. */
export function dbErrorMessage(err: unknown): string | null {
  const e = err as { code?: string; message?: string };
  if (e?.code === "P0001" && e.message) return e.message;
  if (e?.code === "42501") return "لا تملك صلاحية لهذا الإجراء.";
  return null;
}
