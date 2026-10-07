import { logItemAction, logMeasurementsAction, logStepsAction, logWeightAction, rateDayAction } from "@/app/actions/training";
import { deleteFoodLogAction, logFoodAction, logFoodGramsAction } from "@/app/actions/nutrition";
import { cancelOrderAction, submitCheckinAction, submitReviewAction, uploadProofAction, type ActionState } from "@/app/actions/client";

export const dynamic = "force-dynamic";

// تطبيق الجوال يستدعي نفس عمليات الموقع (نفس التحقق والصلاحيات وقاعدة البيانات) بدل نسخها.
// قائمة مغلقة: أي عملية غير مذكورة هنا غير متاحة للتطبيق.
const ACTIONS: Record<string, (s: ActionState, fd: FormData) => Promise<ActionState>> = {
  "log-item": logItemAction,
  "rate-day": rateDayAction,
  "log-weight": logWeightAction,
  "log-measurements": logMeasurementsAction,
  "log-steps": logStepsAction,
  "log-food": logFoodAction,
  "log-food-grams": logFoodGramsAction,
  "delete-food-log": deleteFoodLogAction,
  "upload-proof": uploadProofAction,
  "cancel-order": cancelOrderAction,
  "submit-checkin": submitCheckinAction,
  "submit-review": submitReviewAction,
};

export async function POST(req: Request, { params }: { params: Promise<{ name: string }> }) {
  const action = ACTIONS[(await params).name];
  if (!action) return Response.json({ error: "غير متاح." }, { status: 404 });
  let fd: FormData;
  try { fd = await req.formData(); } catch { return Response.json({ error: "طلب غير صالح." }, { status: 400 }); }
  const res = await action({}, fd);
  return Response.json(res, { status: res.error === "سجّل الدخول أولاً." ? 401 : res.error ? 422 : 200, headers: { "Cache-Control": "no-store" } });
}
