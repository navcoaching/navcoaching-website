import type { MetadataRoute } from "next";
import { getProducts } from "@/lib/data";

export const revalidate = 3600;

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  const products = await getProducts().catch(() => []);
  return [
    ...["", "/programs", "/about", "/faq", "/reviews", "/policies"].map((p) => ({ url: `${site}${p}` })),
    ...products.map((p) => ({ url: `${site}/programs/${p.slug}` })),
  ];
}
