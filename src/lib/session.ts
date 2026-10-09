import "server-only";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { cache } from "react";
import { auth } from "./auth";

export type CurrentUser = { id: string; name: string; email: string; role: "client" | "coach"; phone: string | null };

async function readUser(fresh: boolean): Promise<CurrentUser | null> {
  const session = await auth.api.getSession({ headers: await headers(), ...(fresh ? { query: { disableCookieCache: true } } : {}) });
  if (!session) return null;
  const u = session.user as typeof session.user & { role?: string; phone?: string | null };
  return { id: u.id, name: u.name, email: u.email, role: u.role === "coach" ? "coach" : "client", phone: u.phone ?? null };
}

/** هوية المستخدم من الكوكي الموقّع (تُجدَّد من قاعدة البيانات كل 5 دقائق): سريعة، للصفحات العادية. لا تعتمد عليها في صلاحية المدربة */
export const getCurrentUser = cache(() => readUser(false));

/** هوية محدّثة من قاعدة البيانات (بدون كاش الكوكي): لكل فحص «هل هي المدربة؟» حتى ينعكس تغيير الدور فوراً */
export const getFreshUser = cache(() => readUser(true));

export async function requireUser(next?: string): Promise<CurrentUser> {
  const user = await getCurrentUser();
  if (!user) redirect(`/login${next ? `?next=${encodeURIComponent(next)}` : ""}`);
  return user;
}

/** حماية لوحة الإدارة على الخادم؛ وقاعدة البيانات تتحقق من الدور مرة ثانية في كل عملية. */
export async function requireCoach(): Promise<CurrentUser> {
  const user = await getFreshUser();
  if (!user) redirect("/login?next=%2Fadmin");
  if (user.role !== "coach") redirect("/account?denied=1");
  return user;
}

/** للمسارات المسموحة فقط بعد الدخول: يمنع إعادة التوجيه لمواقع خارجية */
export function safeNext(next: string | null | undefined, fallback = "/account") {
  if (!next || !next.startsWith("/") || next.startsWith("//") || next.startsWith("/\\")) return fallback;
  return next;
}
