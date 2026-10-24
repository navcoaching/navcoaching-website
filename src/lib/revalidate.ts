import { revalidatePath as next } from "next/cache";

/**
 * الصفحات العامة وحساب المتدرب تحت المقطع [lang] (العربية تُعاد كتابتها داخلياً إلى /ar/...)،
 * فتحويل المسارات هنا يبقي استدعاءات revalidatePath في الإجراءات كما كانت بروابط الموقع.
 */
export function revalidatePath(path: string, type?: "page" | "layout") {
  if (path.startsWith("/admin") || (path === "/" && type === "layout")) return next(path, type);
  if (/^\/(account|login|checkout)(\/|$)/.test(path)) return next(`/ar${path}`, type);
  next(`/ar${path === "/" ? "" : path}`, type);
  next(`/en${path === "/" ? "" : path}`, type);
}
