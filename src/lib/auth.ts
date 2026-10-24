import { betterAuth } from "better-auth";
import { emailOTP } from "better-auth/plugins";
import { nextCookies } from "better-auth/next-js";
import { expo } from "@better-auth/expo";
import { pool } from "./db";
import { mailBrand, notifySafe, sendMail } from "./mail";
import { renderEmail } from "./email-template";
import { allow } from "./rate";
import { APIError, createAuthMiddleware } from "better-auth/api";
import { LOGIN_LOCK_AFTER, logSecurity, loginFailures, reportIssue } from "./ops";
import { TURNSTILE_ERROR, verifyTurnstile } from "./turnstile";

const ipOf = (h?: Headers) => h?.get("x-nf-client-connection-ip") ?? h?.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;

/**
 * الدخول برمز مؤقت يصل للبريد (بدون كلمة مرور): أبسط على الجوال ولا يوجد كلمات مرور تتسرب.
 * - الرمز 6 أرقام، صالح 10 دقائق، 5 محاولات، ومخزّن مشفّراً (hashed).
 * - حد الطلبات مخزّن في قاعدة البيانات ليعمل على الاستضافة بدون خادم دائم.
 * - الدور (client/coach) لا يمكن تعيينه من الواجهة (input: false).
 */
export const auth = betterAuth({
  appName: "Nav Coaching",
  database: pool,
  secret: process.env.BETTER_AUTH_SECRET,
  baseURL: process.env.BETTER_AUTH_URL,
  // تطبيق الجوال (mobile/) يدخل بنفس رمز البريد؛ يحفظ الجلسة في SecureStore ويرسلها مع كل طلب.
  // exp:// لتطبيق Expo Go أثناء التطوير فقط.
  trustedOrigins: ["navcoaching://", ...(process.env.NODE_ENV === "development" ? ["exp://", "exp://**"] : [])],
  user: {
    additionalFields: {
      role: { type: "string", required: false, defaultValue: "client", input: false },
      phone: { type: "string", required: false, input: false },
    },
  },
  // تنبيه المدربة بكل تسجيل جديد. الحساب لا يُنشأ إلا بعد إدخال رمز صحيح من البريد، فالتنبيه لبريد حقيقي فقط.
  databaseHooks: {
    user: {
      create: {
        async after(user) {
          const when = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Riyadh" }).format(new Date());
          await notifySafe(
            process.env.COACH_NOTIFY_EMAIL,
            `تسجيل جديد في Nav Coaching: ${user.email}`,
            `سجّل حساب جديد في الموقع.\nالبريد: ${user.email}\nالوقت: ${when} (بتوقيت الرياض)\n\nالتسجيل لا يعني طلباً بعد؛ يصلك تنبيه منفصل عند إرسال الاستبيان والطلب.\n${process.env.NEXT_PUBLIC_SITE_URL ?? ""}/admin`,
          );
        },
      },
    },
  },
  // الجلسة تنتهي بعد 12 ساعة بلا نشاط: تتجدد مع الاستخدام (كل ساعة على الأكثر)، فمن يستخدم الموقع لا يخرج.
  session: {
    expiresIn: 60 * 60 * 12,
    updateAge: 60 * 60,
    // الجلسة تُقرأ من الكوكي الموقّع لمدة 5 دقائق بدل استعلامين لقاعدة البيانات في كل صفحة.
    // الثمن: تغيير الدور (مدربة/متدرب) أو إلغاء الجلسة من قاعدة البيانات يتأخر حتى 5 دقائق.
    cookieCache: { enabled: true, maxAge: 60 * 5 },
  },
  rateLimit: {
    enabled: true,
    storage: "database",
    window: 60,
    max: 60,
    customRules: {
      "/email-otp/send-verification-otp": { window: 60 * 10, max: 5 },
      "/sign-in/email-otp": { window: 60 * 10, max: 10 },
    },
  },
  // قفل الدخول بعد 5 محاولات خاطئة لنفس البريد (15 دقيقة)، وتسجيل كل محاولة في سجل الأمان.
  hooks: {
    before: createAuthMiddleware(async (ctx) => {
      if (ctx.path !== "/sign-in/email-otp" && ctx.path !== "/email-otp/send-verification-otp") return;
      // Turnstile على طلب رمز الدخول من الموقع. تطبيق الجوال (ترويسة expo-origin من better-auth/expo) لا يملك الودجت،
      // فيبقى محمياً بحدود المعدل فقط (5 لكل IP كل 10 دقائق، و8 لكل بريد بالساعة).
      if (ctx.path === "/email-otp/send-verification-otp" && !ctx.headers?.get("expo-origin") && !(await verifyTurnstile(ctx.headers?.get("x-turnstile-token"), ipOf(ctx.headers))))
        throw new APIError("BAD_REQUEST", { code: "TURNSTILE_FAILED", message: TURNSTILE_ERROR });
      const email = String(ctx.body?.email ?? "").trim().toLowerCase();
      if (!email || (await loginFailures(email)) < LOGIN_LOCK_AFTER) return;
      await logSecurity("login_locked", { email, ip: ipOf(ctx.headers) });
      throw new APIError("TOO_MANY_REQUESTS", { code: "ACCOUNT_LOCKED", message: "الدخول مقفل مؤقتاً بعد 5 محاولات خاطئة. حاول بعد 15 دقيقة." });
    }),
    after: createAuthMiddleware(async (ctx) => {
      if (ctx.path !== "/sign-in/email-otp") return;
      const email = String(ctx.body?.email ?? "").trim().toLowerCase();
      const s = ctx.context.newSession;
      if (s) return logSecurity("login_ok", { email, userId: s.user.id, ip: ipOf(ctx.headers) });
      const r = ctx.context.returned as { body?: { code?: string } } | undefined;
      await logSecurity("login_failed", { email, ip: ipOf(ctx.headers), detail: r?.body?.code ?? null });
    }),
  },
  advanced: {
    useSecureCookies: process.env.NODE_ENV === "production",
    ipAddress: { ipAddressHeaders: ["x-nf-client-connection-ip", "x-forwarded-for"] },
  },
  plugins: [
    emailOTP({
      // حساب مراجعة Apple: المراجع ما يستقبل بريدنا، فلبريد المراجعة فقط رمز ثابت من متغير بيئة سري (انظر reviewLogin)
      generateOTP: ({ email }) => reviewLogin(email) ?? undefined,
      otpLength: 6,
      expiresIn: 60 * 10,
      allowedAttempts: 5,
      storeOTP: "hashed",
      async sendVerificationOTP({ email, otp }) {
        // حدود إضافية على رموز الدخول (كل رمز = إيميل مدفوع من حصة الإرسال):
        // لكل بريد 8 بالساعة (يمنع إغراق بريد شخص من أجهزة كثيرة)، وللموقع كله 300 بالساعة.
        const key = email.trim().toLowerCase();
        if (!(await allow(`otp:email:${key}`, 8, 3600)) || !(await allow("otp:site:hour", 300, 3600))) {
          throw new Error("otp rate limited");
        }
        if (reviewLogin(email)) return; // حساب المراجعة: لا يُرسل بريد (الحدود أعلاه تبقى سارية)
        const brand = await mailBrand(pool).catch(() => ({ site: (process.env.NEXT_PUBLIC_SITE_URL || "https://navcoaching.com").replace(/\/$/, "") }));
        await logSecurity("otp_sent", { email: key });
        await sendMail(
          email,
          `رمز الدخول إلى Nav Coaching: ${otp}`,
          `رمز الدخول: ${otp}\n\nصالح لمدة 10 دقائق. إذا لم يكن طلب الدخول منك فلا حاجة لأي إجراء.\n\nNav Coaching`,
          renderEmail({ headline: "رمز الدخول", code: otp, brand,
            message: "هذا الرمز يُكتب في صفحة الدخول. صالح لمدة 10 دقائق، وإذا لم يكن طلب الدخول منك فلا حاجة لأي إجراء." }),
        ).catch(async (err) => { await reportIssue("login_mail_failed", (err as Error).message); throw err; });
      },
    }),
    expo(),
    nextCookies(),
  ],
});

export type Session = typeof auth.$Infer.Session;

/**
 * دخول مراجع Apple: APP_REVIEW_EMAIL وAPP_REVIEW_CODE (6 أرقام) في متغيرات بيئة الموقع فقط، وليست في الكود.
 * يعمل لهذا البريد وحده، وبنفس حدود رموز الدخول (5 محاولات للرمز، 8 طلبات بالساعة للبريد، وحدود IP).
 * فارغ أو غير صالح = معطّل. يرجع الرمز الثابت لبريد المراجعة، وإلا null.
 */
export function reviewLogin(email: string): string | null {
  const e = (process.env.APP_REVIEW_EMAIL ?? "").trim().toLowerCase();
  const code = (process.env.APP_REVIEW_CODE ?? "").trim();
  if (!e || !/^\d{6}$/.test(code)) return null;
  return email.trim().toLowerCase() === e ? code : null;
}
