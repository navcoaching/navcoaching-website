import "server-only";
import { pool } from "./db";
import { allow } from "./rate";
import { sendMail } from "./mail";
import { pushToCoaches } from "./push";

export type SecurityEvent = "login_ok" | "login_failed" | "login_locked" | "otp_sent" | "account_deleted" | "intake_exported";
export type IssueKind = "server_error" | "mail_failed" | "login_mail_failed" | "push_failed" | "whatsapp_failed";

const ISSUE_LABEL: Record<IssueKind, string> = {
  server_error: "خطأ في الموقع",
  mail_failed: "تعذّر إرسال بريد",
  login_mail_failed: "تعذّر إرسال رمز الدخول",
  push_failed: "تعذّر إرسال إشعار جوال",
  whatsapp_failed: "تعذّر إرسال واتساب",
};

/** سجل الأمان: لا يُفشل العملية الأصلية أبداً */
export async function logSecurity(event: SecurityEvent, v: { email?: string | null; userId?: string | null; ip?: string | null; detail?: string | null }) {
  try {
    await pool.query("SELECT app.log_security($1, $2, $3, $4, $5)", [event, v.email ?? null, v.userId ?? null, v.ip ?? null, v.detail ?? null]);
  } catch (err) {
    console.error("[security-log]", (err as Error).message);
  }
}

/** يسجّل مشكلة تشغيل وينبّه المدربة فوراً (جوال + بريد) بحد تنبيه واحد بالساعة لكل نوع. لا يرمي خطأ. */
export async function reportIssue(kind: IssueKind, detail: string) {
  console.error(`[ops] ${kind}:`, detail);
  try {
    await pool.query("SELECT app.ops_event($1, $2)", [kind, detail.slice(0, 500)]);
    if (!(await allow(`alert:${kind}`, 1, 3600))) return;
    const title = `${ISSUE_LABEL[kind]} — راجعي «الأمان والمراقبة»`;
    const site = (process.env.NEXT_PUBLIC_SITE_URL || "").replace(/\/$/, "");
    await pushToCoaches(title, "/admin/security");
    // تنبيه فشل البريد لا يُرسل بالبريد (غالباً سيفشل هو أيضاً)؛ يكفي الجوال والسجل
    if (!kind.includes("mail") && process.env.COACH_NOTIFY_EMAIL) {
      await sendMail(process.env.COACH_NOTIFY_EMAIL, title, `${detail.slice(0, 500)}\n\nالتفاصيل: ${site}/admin/security`).catch(() => {});
    }
  } catch (err) {
    console.error("[ops] report failed:", (err as Error).message);
  }
}

/** عدد محاولات الدخول الفاشلة الأخيرة لهذا البريد (القفل عند 5) */
export async function loginFailures(email: string): Promise<number> {
  const { rows } = await pool.query("SELECT app.login_failures($1) AS n", [email]);
  return rows[0].n as number;
}
export const LOGIN_LOCK_AFTER = 5;
