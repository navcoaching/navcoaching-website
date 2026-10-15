import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { storage } from "@/lib/storage";

export const dynamic = "force-dynamic";

// تنزيل جدول مجاني: فقط لصاحب الطلب (تتحقق قاعدة البيانات من الملكية عبر app.free_plan_file).
// الأخطاء تعيد المستخدم لحسابه برسالة واضحة بدل صفحة خطأ خام.
const back = (req: Request, path: string) => Response.redirect(new URL(path, req.url), 303);

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return back(req, "/account?plan=notfound#free-plans");
  const user = await getCurrentUser().catch(() => null);
  if (!user) return back(req, `/login?next=${encodeURIComponent("/account#free-plans")}`);

  const row = await withUser(user.id, async (tx) => (await tx.query("SELECT * FROM app.free_plan_file($1)", [id])).rows[0]);
  if (!row) return back(req, "/account?plan=notfound#free-plans");
  if (!row.file_key) return back(req, "/account?plan=unavailable#free-plans");

  let data: Buffer | null = null;
  try { data = await (await storage()).get(row.file_key); } catch { data = null; }
  if (!data) return back(req, "/account?plan=unavailable#free-plans");

  return new Response(new Uint8Array(data), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Length": String(data.length),
      "Content-Disposition": `attachment; filename="nav-${row.slug}.pdf"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; sandbox",
    },
  });
}
