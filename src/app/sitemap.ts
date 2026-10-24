import type { MetadataRoute } from "next";
import { getFreePlans, getProducts } from "@/lib/data";
import { href, LANGS } from "@/lib/lang";

export const revalidate = 3600;

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  const [products, plans] = await Promise.all([getProducts().catch(() => []), getFreePlans(null).catch(() => [])]);
  const paths = [
    "/", "/programs", "/about", "/faq", "/reviews", "/policies", "/calculator", "/free-plans", "/booklets", "/video-guide", "/program-preview",
    ...products.map((p) => `/programs/${p.slug}`),
    ...plans.map((p) => `/free-plans/${p.slug}`),
  ];
  // كل صفحة بلغتيها، مع بدائل اللغات (hreflang) لكل رابط
  return [
    ...LANGS.flatMap((lang) => paths.map((p) => ({
      url: `${site}${href(lang, p)}`,
      alternates: { languages: { ar: `${site}${href("ar", p)}`, en: `${site}${href("en", p)}` } },
    }))),
    { url: `${site}/install` },
  ];
}
