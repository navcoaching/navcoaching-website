import "server-only";
import { dbErrorMessage, withUser } from "./db";
import { intakeSchema, normalizedPhone, splitIntake } from "./intake";
import { parseConfig, validateCustomAnswers } from "./intake-config";
import { getSettings } from "./data";
import { allow, clientIp } from "./rate";
import { notifySafe } from "./mail";
import { riyals } from "./format";
import { startPrefLabel } from "./schedule";
import { differentPerson } from "./names";
import { getFreshUser } from "./session";

type Result = { orderNo: string } | { error: string; fieldErrors?: Record<string, string> };

const GENERIC = "حدث خطأ غير متوقع. حاول مرة أخرى أو تواصل معنا على واتساب.";

function formToObject(fd: FormData) {
  const o: Record<string, unknown> = {};
  for (const key of new Set(fd.keys())) {
    if (key.startsWith("$ACTION")) continue;
    o[key] = key === "equip" ? fd.getAll(key) : fd.get(key);
  }
  return o;
}

// ملاحظة أمان: تأخذ هوية المستخدم كمعامل، فلا تُصدَّر من ملف "use server" (كان ذلك سيجعلها نقطة طلب عامة).
/** إنشاء الطلب مع الاستبيان (الموقع والتطبيق): نفس التحقق، والسعر والصلاحيات من قاعدة البيانات، ومفتاح منع التكرار */
export async function createOrder(userId: string, fd: FormData): Promise<Result> {
  // الأسئلة الإضافية من إعدادات لوحة الإدارة (تُتحقق في الخادم مثل باقي الحقول)
  const custom = validateCustomAnswers(parseConfig((await getSettings()).intake_questions), (k) => String(fd.get(k) ?? ""));
  const parsed = intakeSchema.safeParse(formToObject(fd));
  if (!parsed.success || Object.keys(custom.errors).length) {
    const fieldErrors: Record<string, string> = {};
    if (!parsed.success) for (const issue of parsed.error.issues) fieldErrors[String(issue.path[0])] ??= issue.message;
    if (fieldErrors.website) return { error: GENERIC };
    return { error: "راجع الحقول المحددة.", fieldErrors: { ...fieldErrors, ...custom.errors } };
  }
  const v = parsed.data;
  // طلب باسم شخص غير صاحب الحساب: يُضاف لهذا الحساب ويشوفه صاحب البريد، فنطلب تأكيداً صريحاً
  // الاسم من قاعدة البيانات مباشرة (كوكي الجلسة قد يحمل اسماً قديماً حتى 5 دقائق)
  const owner = fd.get("for_me") === "on" ? null : await getFreshUser();
  if (owner && owner.id === userId && differentPerson(owner.name, v.name, owner.email)) {
    return {
      error: `أنت مسجّل بحساب «${owner.name}» (${owner.email})، والطلب باسم «${v.name}». الطلب يُضاف لهذا الحساب فقط.`,
      fieldErrors: { for_me: "إذا الطلب لشخص آخر سجّل خروج وخلّه يطلب من حسابه. وإذا الطلب لك فعّل التأكيد:" },
    };
  }

  if (!(await allow(`order:u:${userId}`, 6, 3600)) || !(await allow(`order:ip:${await clientIp()}`, 20, 3600)))
    return { error: "محاولات كثيرة خلال وقت قصير. انتظر قليلاً ثم حاول مرة أخرى." };

  const { answers: baseAnswers, health, healthFlag } = splitIntake(v);
  const answers = custom.answers.length ? { ...baseAnswers, custom: custom.answers } : baseAnswers;
  let orderNo: string;
  try {
    orderNo = await withUser(userId, async (tx) => {
      const { rows } = await tx.query(
        "SELECT app.create_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS no",
        [v.sku, v.idempotency_key, v.student === "نعم", v.name, normalizedPhone(v.cc, v.phone),
         JSON.stringify(answers), JSON.stringify(health), healthFlag, v.media, v.notes],
      );
      if (v.start_mode === "date") await tx.query("SELECT app.set_my_start_pref($1, $2::date)", [rows[0].no, v.start_date]);
      return rows[0].no as string;
    });
  } catch (err) {
    return { error: dbErrorMessage(err) ?? GENERIC };
  }

  const summary = await withUser(userId, async (tx) =>
    (await tx.query("SELECT product_name, offer_label, amount_due_halalas, preferred_start::text FROM orders WHERE order_no = $1", [orderNo])).rows[0]);
  await notifySafe(
    process.env.COACH_NOTIFY_EMAIL,
    `طلب جديد ${orderNo}`,
    `طلب جديد في Nav Coaching\nرقم الطلب: ${orderNo}\nالبرنامج: ${summary.product_name} — ${summary.offer_label}\nالمبلغ: ${summary.amount_due_halalas == null ? "بانتظار تأكيد خصم الطالب" : riyals(summary.amount_due_halalas)}\nموعد البداية: ${startPrefLabel(summary.preferred_start).text}\n\nالتفاصيل في لوحة الإدارة.`,
  );
  return { orderNo };
}
