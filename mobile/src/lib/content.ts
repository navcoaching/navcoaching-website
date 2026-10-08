import { useCallback, useEffect, useState } from "react";
import { api } from "./api";

export type Product = {
  slug: string; category: "follow" | "files" | "consult"; name: string; audience: string;
  items: { text: string; included: boolean }[]; note: string | null; delivery: string | null; requirements: string | null;
  policy_note: string | null; recommended: boolean; image_id: string | null;
  offers: { sku: string; label: string; months: number; price_halalas: number }[];
};
export type Content = {
  hero: { eyebrow: string; title: string; title_tail: string; lead: string; tagline: string };
  badges: string[]; why: { title: string; body: string }[]; how_steps: { title: string; body: string }[];
  about: { name: string; bio: string; points: string[]; certs: string[]; story_title?: string; story?: string[];
    pillars_title?: string; pillars?: { title: string; body: string }[]; experience_title?: string; experience?: string[] };
  about_photos: { id: string; alt: string }[];
  /** الطلب من التطبيق (مفتاح لوحة الإدارة). false = الباقات تعريفية بدون أسعار ولا طلب */
  ordering: boolean;
  prices_note: string; testimonials_disclaimer: string; contact: { whatsapp: string; instagram: string }; response_time: string;
  legal: { name: string; cr: string }; intro_video?: { url: string; title: string; body: string };
  products: Product[];
  faqs: { q: string; a: string }[];
  policies: { slug: string; title: string; body: string }[];
  reviews: { id: string; rating: number | null; body: string; name: string; product: string | null; period: string | null; reply: string | null; source: string }[];
  free_plans: { slug: string; title: string; summary: string; audience: string | null; image_id: string | null }[];
};

let cache: Content | null = null;

/** محتوى الموقع العام (يُطلب مرة لكل تشغيل؛ آخر نسخة تبقى في الذاكرة) */
export function useContent() {
  const [data, setData] = useState<Content | null>(cache);
  const [failed, setFailed] = useState(false);
  const reload = useCallback(() => {
    setFailed(false);
    api<Content>("/content").then((c) => { cache = c; setData(c); }).catch(() => setFailed(true));
  }, []);
  useEffect(() => { if (!cache) reload(); }, [reload]);
  return { data, failed, reload };
}

export const riyals = (h: number) => `${(h / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })} ر.س`;
