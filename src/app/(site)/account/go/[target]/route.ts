import { NextResponse, type NextRequest } from "next/server";
import { getCurrentUser } from "@/lib/session";
import { loadCurrentOrder } from "@/lib/current-order";

// اختصارات أيقونة التطبيق (manifest shortcuts): تفتح صفحة الاشتراك الحالي مباشرة
const TARGETS: Record<string, (base: string) => string> = {
  training: (b) => `${b}/training`,
  food: (b) => `${b}/nutrition`,
  checkin: (b) => `${b}#checkin`,
  progress: (b) => `${b}/progress`,
};

export async function GET(req: NextRequest, { params }: { params: Promise<{ target: string }> }) {
  const { target } = await params;
  const user = await getCurrentUser();
  if (!user) return NextResponse.redirect(new URL(`/login?next=${encodeURIComponent(`/account/go/${target}`)}`, req.url));
  const cur = await loadCurrentOrder(user.id);
  const to = cur && TARGETS[target] ? TARGETS[target](`/account/orders/${cur.order_no}`) : "/account";
  return NextResponse.redirect(new URL(to, req.url));
}
