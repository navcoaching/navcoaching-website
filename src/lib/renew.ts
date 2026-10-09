import "server-only";
import { dbErrorMessage, withUser } from "./db";
import { allow } from "./rate";
import { notifySafe } from "./mail";
import { riyals } from "./format";

// ملاحظة أمان: هذه الدالة تأخذ هوية المستخدم كمعامل، فلا تُصدَّر من ملف "use server" (كان ذلك سيجعلها نقطة طلب عامة).
/** طلب التجديد بخصم (الموقع والتطبيق): قاعدة البيانات تتحقق من الفترة والسعر، ولا يتكرر الطلب نفسه */
export async function createRenewal(userId: string, orderNo: string): Promise<{ no: string } | { error: string }> {
  if (!(await allow(`renew:u:${userId}`, 10, 3600))) return { error: "محاولات كثيرة خلال وقت قصير. انتظر قليلاً ثم حاول مرة أخرى." };
  let r: { no: string; product_name: string; amount_due_halalas: number; created: boolean };
  try {
    r = await withUser(userId, async (tx) => {
      const before = (await tx.query(
        "SELECT count(*)::int n FROM orders WHERE renewal_of = (SELECT id FROM orders WHERE order_no = $1) AND renewal_kind = 'renewal' AND status <> 'cancelled'", [orderNo])).rows[0].n;
      const no = (await tx.query("SELECT app.create_renewal($1) AS no", [orderNo])).rows[0].no as string;
      const o = (await tx.query("SELECT product_name, amount_due_halalas FROM orders WHERE order_no = $1", [no])).rows[0];
      return { no, ...o, created: before === 0 };
    });
  } catch (err) {
    return { error: dbErrorMessage(err) ?? "حدث خطأ غير متوقع. حاول مرة أخرى أو تواصل معنا على واتساب." };
  }
  if (r.created) {
    await notifySafe(process.env.COACH_NOTIFY_EMAIL, `طلب تجديد بخصم 10% — ${r.no}`,
      `طلب تجديد جديد بخصم 10%\nرقم الطلب: ${r.no}\nالبرنامج: ${r.product_name}\nالمبلغ: ${riyals(r.amount_due_halalas)}\nالاشتراك السابق: ${orderNo}\n\nالتفاصيل في لوحة الإدارة.`);
  }
  return { no: r.no };
}
