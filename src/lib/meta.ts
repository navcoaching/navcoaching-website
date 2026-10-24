import type { Metadata } from "next";
import { href, type Lang } from "./lang";

const site = () => process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

/** عنوان ووصف الصفحة مع الرابط الأساسي وبدائل اللغات (hreflang) لنفس المسار */
export function pageMeta(lang: Lang, path: string, m: { title?: string; description?: string; noindex?: boolean } = {}): Metadata {
  const abs = (l: Lang) => `${site()}${href(l, path)}`;
  return {
    ...(m.title ? { title: m.title } : {}),
    ...(m.description ? { description: m.description } : {}),
    ...(m.noindex ? { robots: { index: false } } : {}),
    alternates: { canonical: abs(lang), languages: { ar: abs("ar"), en: abs("en"), "x-default": abs("ar") } },
  };
}
