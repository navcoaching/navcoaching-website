import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { storage } from "@/lib/storage";

export const dynamic = "force-dynamic";

// تحميل كتيب: قاعدة البيانات (RLS) تسمح فقط للمدربة ولمن عنده اشتراك. الأخطاء ترجع المستخدم لحسابه برسالة.
const back = (req: Request, path: string) => Response.redirect(new URL(path, req.url), 303);

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) return back(req, "/account?booklet=notfound#booklets");
  const user = await getCurrentUser().catch(() => null);
  if (!user) return back(req, `/login?next=${encodeURIComponent("/account#booklets")}`);

  const row = await withUser(user.id, async (tx) => (await tx.query("SELECT title, file_key FROM booklets WHERE id = $1", [id])).rows[0]);
  if (!row) return back(req, "/account?booklet=notfound#booklets");
  let data: Buffer | null = null;
  try { data = await (await storage()).get(row.file_key); } catch { data = null; }
  if (!data) return back(req, "/account?booklet=unavailable#booklets");

  const name = `${String(row.title).replace(/[\\/:*?"<>|\r\n]+/g, " ").trim() || "booklet"}.pdf`;
  return new Response(new Uint8Array(data), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Length": String(data.length),
      "Content-Disposition": `attachment; filename="nav-booklet.pdf"; filename*=UTF-8''${encodeURIComponent(name)}`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": "default-src 'none'; sandbox",
    },
  });
}
