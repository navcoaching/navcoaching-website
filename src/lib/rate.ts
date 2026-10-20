import "server-only";
import { headers } from "next/headers";
import { pool } from "./db";

export async function clientIp(): Promise<string> {
  const h = await headers();
  return h.get("x-nf-client-connection-ip") ?? h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "local";
}

/** يرجع false عند تجاوز الحد. المفتاح يجمع نوع العملية والمستخدم أو عنوان IP. */
export async function allow(key: string, max: number, windowSeconds: number): Promise<boolean> {
  const { rows } = await pool.query("SELECT app.rate_limit($1, $2, $3) AS ok", [key, max, windowSeconds]);
  return rows[0].ok as boolean;
}
