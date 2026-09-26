import { betterAuth } from "better-auth";
import { emailOTP } from "better-auth/plugins";
import { nextCookies } from "better-auth/next-js";
import { pool } from "./db";
import { notifySafe, sendMail } from "./mail";

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
      otpLength: 6,
      expiresIn: 60 * 10,
      allowedAttempts: 5,
      storeOTP: "hashed",
      async sendVerificationOTP({ email, otp }) {
        await sendMail(
          email,
          `رمز الدخول إلى Nav Coaching: ${otp}`,
          `رمز الدخول: ${otp}\n\nصالح لمدة 10 دقائق. إذا لم تطلب الدخول تجاهل هذه الرسالة.\n\nNav Coaching`,
        );
      },
    }),
    nextCookies(),
  ],
});

export type Session = typeof auth.$Infer.Session;
