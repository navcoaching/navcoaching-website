import { betterAuth } from "better-auth";
import { emailOTP } from "better-auth/plugins";
import { nextCookies } from "better-auth/next-js";
import { expo } from "@better-auth/expo";
import { pool } from "./db";
import { mailBrand, notifySafe, sendMail } from "./mail";
import { renderEmail } from "./email-template";
import { allow } from "./rate";

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
  session: {
    expiresIn: 60 * 60 * 24 * 14,
    updateAge: 60 * 60 * 24,
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
        await sendMail(
          email,
          `رمز الدخول إلى Nav Coaching: ${otp}`,
          `رمز الدخول: ${otp}\n\nصالح لمدة 10 دقائق. إذا لم تطلب الدخول تجاهل هذه الرسالة.\n\nNav Coaching`,
          renderEmail({ headline: "رمز الدخول 🔐", code: otp, brand,
            message: "اكتب هذا الرمز في صفحة الدخول. صالح لمدة 10 دقائق، وإذا لم تطلب الدخول تجاهل هذه الرسالة." }),
        );
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
