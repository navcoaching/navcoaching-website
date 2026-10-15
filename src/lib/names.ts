// مقارنة الأسماء لكشف طلب باسم شخص غير صاحب الحساب (مثل طلب غيداء داخل حساب سارة).
// تطبيع عربي بسيط: الهمزات، التاء المربوطة/الهاء، الألف المقصورة، التشكيل، والمسافات.

export function normName(s: string | null | undefined): string {
  return (s ?? "")
    .toLowerCase()
    .replace(/[ً-ْـ]/g, "") // تشكيل وتطويل
    .replace(/[أإآٱ]/g, "ا").replace(/ة/g, "ه").replace(/ى/g, "ي").replace(/ؤ/g, "و").replace(/ئ/g, "ي")
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const firstName = (s: string) => normName(s).split(" ").find((w) => w.length > 1 && w !== "ال") ?? "";

/**
 * هل الاسمان لشخصين مختلفين؟ نقارن الاسم الأول فقط (الطلب قد يكون بالاسم الكامل والحساب بالأول).
 * الاسم الفارغ أو المأخوذ من البريد لا يُعتبر اختلافاً (ما نعرف اسم صاحب الحساب).
 */
export function differentPerson(accountName: string | null | undefined, orderName: string | null | undefined, email?: string | null): boolean {
  const a = firstName(accountName ?? ""), b = firstName(orderName ?? "");
  if (!a || !b) return false;
  if (email && normName(accountName) === normName(email.split("@")[0])) return false;
  // الأسماء اللاتينية والعربية لنفس الشخص (Sarah / سارة) ما نقدر نحكم عليها: نعتبرها مختلفة فقط إذا كانت بنفس الكتابة
  const latin = (x: string) => /^[a-z0-9 ]+$/.test(x);
  if (latin(a) !== latin(b)) return false;
  return !(a === b || a.startsWith(b) || b.startsWith(a));
}
