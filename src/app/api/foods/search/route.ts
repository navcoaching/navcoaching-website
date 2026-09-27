import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { allow } from "@/lib/rate";
import { fatsecretEnabled, fatsecretSearch } from "@/lib/fatsecret";

export const dynamic = "force-dynamic";

// بحث الأكل للمتدرب: قاعدة الموقع أولاً (عربي/إنجليزي)، ثم FatSecret إن كان مفعّلاً.
export async function GET(req: Request) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const q = (new URL(req.url).searchParams.get("q") ?? "").trim().slice(0, 60);
  if (q.length < 2) return Response.json({ local: [], external: [], external_enabled: fatsecretEnabled() });
  if (!(await allow(`foodsearch:u:${user.id}`, 60, 60))) return Response.json({ error: "limited" }, { status: 429 });

  const local = await withUser(user.id, async (tx) => (await tx.query(
    `SELECT id, name_ar, name_en, category, kcal_100::float, protein_100::float, carbs_100::float, fat_100::float, serving_g::float, serving_label
       FROM foods
      WHERE active AND (name_ar ILIKE '%' || $1 || '%' OR coalesce(name_en, '') ILIKE '%' || $1 || '%')
      ORDER BY (name_ar ILIKE $1 || '%') DESC, length(name_ar), name_ar LIMIT 20`, [q])).rows);

  let external: Awaited<ReturnType<typeof fatsecretSearch>> = [];
  let externalError = false;
  if (fatsecretEnabled() && local.length < 8) {
    try { external = await fatsecretSearch(q); } catch (err) { console.error("[fatsecret]", (err as Error).message); externalError = true; }
  }
  return Response.json({ local, external, external_enabled: fatsecretEnabled(), external_error: externalError }, { headers: { "Cache-Control": "private, no-store" } });
}
