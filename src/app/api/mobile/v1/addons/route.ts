import { getCurrentUser } from "@/lib/session";
import { createAddonOrder, listAddons } from "@/lib/addons";
import { riyals } from "@/lib/format";

export const dynamic = "force-dynamic";

// الخدمات الإضافية بأسعار رمزية (عامة للعرض، والطلب يحتاج دخول)
export async function GET() {
  const rows = await listAddons();
  return Response.json({ addons: rows.map((r) => ({ kind: r.kind, name: r.name, about: r.audience, items: r.items, sku: r.sku, label: r.label, price: riyals(r.price_halalas) })) },
    { headers: { "Cache-Control": "public, max-age=60" } });
}

export async function POST(req: Request) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "سجّل الدخول أولاً." }, { status: 401 });
  let fd: FormData;
  try { fd = await req.formData(); } catch { return Response.json({ error: "الملف كبير جداً أو الطلب غير صالح." }, { status: 400 }); }
  const r = await createAddonOrder(user, fd);
  return Response.json(r, { status: "error" in r ? 422 : 200, headers: { "Cache-Control": "no-store" } });
}
