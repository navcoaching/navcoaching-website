// بحث FatSecret (اختياري): يعمل فقط عند وجود FATSECRET_CLIENT_ID و FATSECRET_CLIENT_SECRET.
// الطلبات من الخادم فقط، والقيم لكل 100غ تُحسب من الحصة المترية (بالغرام) التي يرجعها FatSecret.
// شرط الاستخدام: إظهار «Powered by fatsecret» مع النتائج.

const TOKEN_URL = "https://oauth.fatsecret.com/connect/token";
const API_URL = "https://platform.fatsecret.com/rest/server.api";

export const fatsecretEnabled = () => Boolean(process.env.FATSECRET_CLIENT_ID && process.env.FATSECRET_CLIENT_SECRET);

let cached: { token: string; exp: number } | null = null;
async function token() {
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;
  const auth = Buffer.from(`${process.env.FATSECRET_CLIENT_ID}:${process.env.FATSECRET_CLIENT_SECRET}`).toString("base64");
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: process.env.FATSECRET_SCOPE || "basic" }),
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) throw new Error(`fatsecret token ${res.status}`);
  const j = (await res.json()) as { access_token: string; expires_in: number };
  cached = { token: j.access_token, exp: Date.now() + j.expires_in * 1000 };
  return cached.token;
}

async function call(params: Record<string, string>) {
  const q = new URLSearchParams({ ...params, format: "json" });
  if (process.env.FATSECRET_REGION) q.set("region", process.env.FATSECRET_REGION);
  if (process.env.FATSECRET_LANGUAGE) q.set("language", process.env.FATSECRET_LANGUAGE);
  const res = await fetch(`${API_URL}?${q}`, { headers: { Authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`fatsecret ${res.status}`);
  const j = await res.json();
  if (j?.error) throw new Error(`fatsecret error ${j.error.code}: ${j.error.message}`);
  return j;
}

export type ExternalFood = { id: string; name: string; brand: string | null; protein_100: number; carbs_100: number; fat_100: number; kcal_100: number; serving_g: number | null };
type Serving = { metric_serving_amount?: string; metric_serving_unit?: string; protein?: string; carbohydrate?: string; fat?: string; calories?: string; is_default?: string };
const arr = <T,>(v: T | T[] | undefined): T[] => (v == null ? [] : Array.isArray(v) ? v : [v]);

/** تحويل حصص FatSecret إلى قيم لكل 100غ (من أول حصة مترية بالغرام؛ الافتراضية أولاً) */
export function per100FromServings(servings: Serving[]): Omit<ExternalFood, "id" | "name" | "brand"> | null {
  const metric = servings.filter((s) => s.metric_serving_unit === "g" && Number(s.metric_serving_amount) > 0);
  const s = metric.find((x) => x.is_default === "1") ?? metric[0];
  if (!s) return null;
  const k = 100 / Number(s.metric_serving_amount);
  const r = (v?: string) => Math.round(Number(v ?? 0) * k * 10) / 10;
  const out = { protein_100: r(s.protein), carbs_100: r(s.carbohydrate), fat_100: r(s.fat), kcal_100: r(s.calories), serving_g: Math.round(Number(s.metric_serving_amount) * 10) / 10 };
  if ([out.protein_100, out.carbs_100, out.fat_100].some((v) => !Number.isFinite(v) || v < 0 || v > 100)) return null;
  return out;
}

export async function fatsecretGet(id: string): Promise<ExternalFood | null> {
  if (!/^\d{1,12}$/.test(id)) return null;
  const j = await call({ method: "food.get.v4", food_id: id });
  const f = j?.food;
  if (!f) return null;
  const p = per100FromServings(arr<Serving>(f.servings?.serving));
  return p ? { id: String(f.food_id), name: String(f.food_name), brand: f.brand_name ? String(f.brand_name) : null, ...p } : null;
}

/** بحث بالاسم؛ يرجع المعرّفات والأسماء فقط، والقيم تُجلب بالتفصيل عند الاختيار */
export async function fatsecretSearch(q: string): Promise<{ id: string; name: string; brand: string | null; description: string }[]> {
  const j = await call({ method: "foods.search", search_expression: q, max_results: "10" });
  return arr<{ food_id: string; food_name: string; brand_name?: string; food_description?: string }>(j?.foods?.food)
    .map((f) => ({ id: String(f.food_id), name: f.food_name, brand: f.brand_name ?? null, description: f.food_description ?? "" }));
}
