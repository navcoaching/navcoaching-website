import "server-only";

/** Cloudflare Turnstile: يعمل فقط عند وجود المفتاحين في البيئة. بدونهما لا يُطلب تحقق (التطوير والاختبار). */
export const turnstileEnabled = () => Boolean(process.env.TURNSTILE_SECRET_KEY && process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY);

/** يتحقق من رمز الودجت عند Cloudflare. true إذا كان التحقق معطّلاً أو ناجحاً. */
export async function verifyTurnstile(token: string | null | undefined, ip?: string | null): Promise<boolean> {
  if (!turnstileEnabled()) return true;
  if (!token || token.length > 2048) return false;
  try {
    const body = new URLSearchParams({ secret: process.env.TURNSTILE_SECRET_KEY!, response: token });
    if (ip && ip !== "local") body.set("remoteip", ip);
    const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body, signal: AbortSignal.timeout(8000) });
    return res.ok && Boolean(((await res.json()) as { success?: boolean }).success);
  } catch {
    return false; // تعذّر الوصول لـ Cloudflare: نرفض بدل فتح الباب للروبوتات
  }
}

export const TURNSTILE_ERROR = "تعذّر التحقق من أنك لست روبوتاً. حدّث الصفحة وحاول مرة أخرى.";
