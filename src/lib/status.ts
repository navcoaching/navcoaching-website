// حالات الطلب وخطها الزمني بحسب نوع المنتج. المصدر الوحيد للحقيقة هو قاعدة البيانات (app.coach_transition)،
// وهذا الملف للعرض فقط.

export type OrderStatus =
  | "awaiting_quote"
  | "awaiting_payment"
  | "payment_review"
  | "preparing"
  | "active"
  | "delivered"
  | "completed"
  | "cancelled";
export type Category = "follow" | "files" | "consult";

export function statusLabel(status: string, category: string): string {
  switch (status) {
    case "awaiting_quote": return "بانتظار تأكيد المبلغ";
    case "awaiting_payment": return "بانتظار الدفع";
    case "payment_review": return "جارٍ التحقق من الدفع";
    case "preparing": return category === "consult" ? "قيد التنسيق" : "قيد الإعداد";
    case "active": return "البرنامج نشط";
    case "delivered": return "تم التسليم";
    case "completed": return category === "consult" ? "تمت الجلسة" : category === "follow" ? "انتهى الاشتراك" : "مكتمل";
    case "cancelled": return "تم إلغاء الطلب";
    default: return status;
  }
}

export function statusTone(status: string): "wait" | "action" | "ok" | "muted" {
  if (status === "awaiting_payment" || status === "awaiting_quote") return "action";
  if (status === "payment_review" || status === "preparing") return "wait";
  if (status === "cancelled") return "muted";
  return "ok";
}

/** خطوات الخط الزمني المتوقعة لكل نوع منتج */
export function timelineSteps(category: string, student: boolean): { key: string; label: string }[] {
  const start = [{ key: "received", label: "تم الاستلام" }];
  if (student) start.push({ key: "awaiting_quote", label: "تأكيد المبلغ" });
  const pay = [
    { key: "awaiting_payment", label: "بانتظار الدفع" },
    { key: "payment_review", label: "التحقق من الدفع" },
  ];
  if (category === "follow")
    return [...start, ...pay, { key: "preparing", label: "قيد الإعداد" }, { key: "active", label: "البرنامج نشط" }, { key: "completed", label: "انتهى الاشتراك" }];
  if (category === "files")
    return [...start, ...pay, { key: "preparing", label: "قيد الإعداد" }, { key: "delivered", label: "تم التسليم" }];
  return [...start, ...pay, { key: "preparing", label: "قيد التنسيق" }, { key: "completed", label: "تمت الجلسة" }];
}

export function stepIndex(status: string, category: string, student: boolean) {
  const steps = timelineSteps(category, student);
  const i = steps.findIndex((s) => s.key === status);
  return i === -1 ? steps.length : i;
}

export const ENTITLED: string[] = ["active", "delivered", "completed"];

/** الانتقالات المتاحة للمدربة في الواجهة (مطابقة لقاعدة البيانات) */
export function coachNextSteps(status: string, category: string): { to: string; label: string; needsBank?: boolean; needsNote?: boolean }[] {
  const out: { to: string; label: string; needsBank?: boolean; needsNote?: boolean }[] = [];
  // تأكيد الدفع (من الإيصال أو دفع مستلم خارج الموقع): إلى «قيد الإعداد» أو «تفعيل البرنامج» مباشرة
  if (status === "payment_review" || status === "awaiting_payment") {
    out.push({ to: "preparing", label: "قيد الإعداد (تأكيد الدفع)", needsBank: true });
    if (category === "follow") out.push({ to: "active", label: "تفعيل البرنامج (تأكيد الدفع)", needsBank: true });
  }
  if (status === "payment_review") out.push({ to: "awaiting_payment", label: "رفض الإيصال وإعادته للعميل", needsNote: true });
  if (status === "preparing") {
    if (category === "follow") out.push({ to: "active", label: "تفعيل البرنامج" });
    if (category === "files") out.push({ to: "delivered", label: "تم التسليم" });
    if (category === "consult") out.push({ to: "completed", label: "تمت الجلسة" });
  }
  if (status === "active") out.push({ to: "completed", label: category === "follow" ? "انتهى الاشتراك (إنهاء الآن)" : "مكتمل" });
  if (status === "delivered") out.push({ to: "completed", label: "مكتمل" });
  if (!["completed", "cancelled"].includes(status)) out.push({ to: "cancelled", label: "تم إلغاء الطلب", needsNote: true });
  return out;
}
/** حالات قبل التفعيل: يقدر المتدرب يغيّر فيها موعد البداية، ويظهر للمدربة تاق الأولوية */
export const PRE_ACTIVE: string[] = ["awaiting_quote", "awaiting_payment", "payment_review", "preparing"];
