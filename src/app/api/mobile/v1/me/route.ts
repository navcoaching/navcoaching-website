import { getFreshUser } from "@/lib/session";
import { loadCurrentOrder } from "@/lib/current-order";

export const dynamic = "force-dynamic";

// تطبيق الجوال: هوية المستخدم واشتراكه الحالي (إن وُجد). الجلسة تصل من التطبيق في ترويسة Cookie مثل المتصفح.
// coaching = null يعني مستخدم مجاني: المتتبّع يعمل له، ومنطقة المتدرب مخفية.
// هوية محدّثة من قاعدة البيانات (بدون كاش الكوكي 5 دقائق) حتى ينعكس حذف الحساب أو إلغاء الجلسة فوراً
export async function GET() {
  const user = await getFreshUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const order = await loadCurrentOrder(user.id);
  return Response.json(
    {
      user: { id: user.id, name: user.name, email: user.email },
      coaching: order ? { orderNo: order.order_no, training: order.training, nutrition: order.nutrition } : null,
    },
    { headers: { "Cache-Control": "private, no-store" } },
  );
}
