import type { Metadata, Viewport } from "next";
import { notFound } from "next/navigation";
import RootHtml from "@/components/RootHtml";
import { isLang, LANGS, type Lang } from "@/lib/lang";

const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

const META: Record<Lang, { title: string; description: string; locale: string }> = {
  ar: { title: "Nav Coaching — برامج تدريب وتغذية مخصصة لأهدافك", description: "برامج تدريب وتغذية مخصصة لأهدافك مع الكوتش ساره: خطة منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.", locale: "ar_SA" },
  en: { title: "Nav Coaching — Personalised training and nutrition programs", description: "Personalised training and nutrition programs with Coach Sara: a structured plan, progress tracking, and weekly adjustments that fit your level and routine.", locale: "en_US" },
};

export const viewport: Viewport = { themeColor: "#07142a", width: "device-width", initialScale: 1, viewportFit: "cover" };

export function generateStaticParams() {
  return LANGS.map((lang) => ({ lang }));
}

export async function generateMetadata({ params }: { params: Promise<{ lang: string }> }): Promise<Metadata> {
  const { lang } = await params;
  const m = META[isLang(lang) ? lang : "ar"];
  return {
    metadataBase: new URL(site),
    title: { default: m.title, template: "%s — Nav Coaching" },
    description: m.description,
    openGraph: { type: "website", locale: m.locale, siteName: "Nav Coaching", images: [{ url: "/brand/og.png", width: 1200, height: 630, alt: "Nav Coaching" }] },
    twitter: { card: "summary_large_image" },
    appleWebApp: { capable: true, title: "Nav Coaching", statusBarStyle: "default" },
  };
}

export default async function RootLayout({ children, params }: { children: React.ReactNode; params: Promise<{ lang: string }> }) {
  const { lang } = await params;
  if (!isLang(lang)) notFound();
  return <RootHtml lang={lang}>{children}</RootHtml>;
}
