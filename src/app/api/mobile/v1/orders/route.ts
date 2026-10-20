import { withUser } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { getSettings } from "@/lib/data";
import { riyals } from "@/lib/format";
import { statusLabel } from "@/lib/status";

export const dynamic = "force-dynamic";

// طلبات المستخدم في التطبيق: الحالة، والمبلغ، وبيانات التحويل للطلب الذي ينتظر الدفع
export async function GET() {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const [rows, s] = await Promise.all([
    withUser(user.id, async (tx) => (await tx.query(
      `SELECT order_no, product_name, status, category, coalesce(amount_due_halalas, list_price_halalas) AS halalas, created_at
         FROM orders WHERE user_id = $1 AND status <> 'cancelled' ORDER BY created_at DESC LIMIT 20`, [user.id])).rows),
    getSettings(),
  ]);
  const needsBank = rows.some((o) => o.status === "awaiting_payment");
  return Response.json({
    orders: rows.map((o) => ({
      order_no: o.order_no, product_name: o.product_name, status: o.status,
      status_label: statusLabel(o.status, o.category), amount: o.halalas == null ? null : riyals(o.halalas), created_at: o.created_at,
    })),
    bank: needsBank ? s.bank : null,
  }, { headers: { "Cache-Control": "private, no-store" } });
}
