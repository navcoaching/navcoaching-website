import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { storage } from "@/lib/storage";

export const dynamic = "force-dynamic";

// كل ملف يُقرأ من التخزين الخاص فقط بعد أن تسمح به قاعدة البيانات (RLS) لهذا المستخدم،
// ومع شرط الملكية مكتوباً في الاستعلام نفسه (حماية ثانية لو تعطّلت RLS بإعداد اتصال خاطئ).
const QUERIES: Record<string, string> = {
  proof: "SELECT storage_key, mime FROM payment_proofs WHERE id = $1 AND (user_id = app.uid() OR app.is_coach())",
  deliverable: "SELECT storage_key, mime, title FROM deliverables WHERE id = $1 AND kind = 'file' AND (app.is_coach() OR app.order_entitled(order_id))",
  media: "SELECT storage_key, mime, approved FROM media_assets WHERE id = $1 AND (approved OR app.is_coach())",
  // فيديو «تصحيح أداء تمرين»: المعرّف رقم الطلب الداخلي (صاحب الطلب والمدربة فقط)
  addon: "SELECT video_key AS storage_key, video_mime AS mime FROM addon_requests a WHERE order_id = $1 AND video_key IS NOT NULL AND (app.is_coach() OR EXISTS (SELECT 1 FROM orders o WHERE o.id = a.order_id AND o.user_id = app.uid()))",
};

export async function GET(_: Request, { params }: { params: Promise<{ kind: string; id: string }> }) {
  const { kind, id } = await params;
  const sql = QUERIES[kind];
  if (!sql || !/^[0-9a-f-]{36}$/.test(id)) return new Response("Not found", { status: 404 });

  const user = kind === "media" ? await getCurrentUser().catch(() => null) : await getCurrentUser();
  if (kind !== "media" && !user) return new Response("Unauthorized", { status: 401 });

  const row = await withUser(user?.id ?? null, async (tx) => (await tx.query(sql, [id])).rows[0]);
  if (!row) return new Response("Not found", { status: 404 });

  const data = await (await storage()).get(row.storage_key);
  if (!data) return new Response("Not found", { status: 404 });

  const inline = row.mime.startsWith("image/") || row.mime.startsWith("video/");
  const ext = row.mime === "application/pdf" ? "pdf" : row.mime.includes("spreadsheet") ? "xlsx" : row.mime.includes("word") ? "docx"
    : row.mime === "video/mp4" ? "mp4" : row.mime === "video/quicktime" ? "mov" : "webp";
  return new Response(new Uint8Array(data), {
    headers: {
      "Content-Type": row.mime,
      "Content-Length": String(data.length),
      "Content-Disposition": `${inline ? "inline" : "attachment"}; filename="nav-${kind}-${id.slice(0, 8)}.${ext}"`,
      "Cache-Control": kind === "media" && row.approved ? "public, max-age=86400" : "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox",
    },
  });
}
