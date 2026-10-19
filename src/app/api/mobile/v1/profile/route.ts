import { getFreshUser } from "@/lib/session";
import { getMyPrefs } from "@/lib/data";

export const dynamic = "force-dynamic";

// الملف الشخصي في التطبيق: الاسم والبريد وتفضيلات التواصل (البريد / واتساب)
export async function GET() {
  const user = await getFreshUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const prefs = await getMyPrefs(user.id);
  return Response.json({ name: user.name, email: user.email, phone: user.phone, prefs: { email: prefs.email_enabled, whatsapp: prefs.whatsapp_enabled } },
    { headers: { "Cache-Control": "private, no-store" } });
}
