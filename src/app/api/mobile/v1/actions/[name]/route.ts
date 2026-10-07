import { logItemAction, logMeasurementsAction, logStepsAction, logWeightAction, rateDayAction, swapExerciseAction } from "@/app/actions/training";
import { deleteFoodLogAction, logFoodAction, logFoodGramsAction } from "@/app/actions/nutrition";
import { cancelOrderAction, savePrefsAction, setStartPrefAction, submitCheckinAction, submitExitSurveyAction, submitReviewAction, updateProfileAction, uploadProofAction, type ActionState } from "@/app/actions/client";
import { createRenewal } from "@/lib/renew";
import { getCurrentUser } from "@/lib/session";

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
  "submit-exit-survey": submitExitSurveyAction,
  "set-start-pref": setStartPrefAction,
  "update-profile": updateProfileAction,
  "save-prefs": savePrefsAction,
  "swap-exercise": swapExerciseAction,
  // التجديد في الموقع ينتهي بتحويل لصفحة الطلب؛ التطبيق يأخذ رقم الطلب الجديد في الرسالة
  renew: async (_, fd) => {
    const user = await getCurrentUser();
    if (!user) return { error: "سجّل الدخول أولاً." };
    const r = await createRenewal(user.id, String(fd.get("order_no") ?? ""));
    return "error" in r ? { error: r.error } : { ok: true, message: r.no };
  },
};

export async function POST(req: Request, { params }: { params: Promise<{ name: string }> }) {
  const action = ACTIONS[(await params).name];
  if (!action) return Response.json({ error: "غير متاح." }, { status: 404 });
  let fd: FormData;
  try { fd = await req.formData(); } catch { return Response.json({ error: "طلب غير صالح." }, { status: 400 }); }
  const res = await action({}, fd);
  return Response.json(res, { status: res.error === "سجّل الدخول أولاً." ? 401 : res.error ? 422 : 200, headers: { "Cache-Control": "no-store" } });
}
