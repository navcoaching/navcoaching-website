import type { MetadataRoute } from "next";
import { getFreePlans, getProducts } from "@/lib/data";

export const revalidate = 3600;

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  const [products, plans] = await Promise.all([getProducts().catch(() => []), getFreePlans(null).catch(() => [])]);
  return [
    ...["", "/programs", "/about", "/faq", "/reviews", "/policies", "/install", "/calculator", "/free-plans"].map((p) => ({ url: `${site}${p}` })),
    ...products.map((p) => ({ url: `${site}/programs/${p.slug}` })),
    ...plans.map((p) => ({ url: `${site}/free-plans/${p.slug}` })),
  ];
}
