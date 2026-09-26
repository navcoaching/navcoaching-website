import type { Metadata, Viewport } from "next";
import "@fontsource-variable/readex-pro";
import "@fontsource/ibm-plex-sans-arabic/400.css";
import "@fontsource/ibm-plex-sans-arabic/500.css";
import "@fontsource/ibm-plex-sans-arabic/600.css";
import "@fontsource/ibm-plex-sans-arabic/700.css";
import "./globals.css";

const site = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

export const metadata: Metadata = {
  metadataBase: new URL(site),
  title: { default: "Nav Coaching — برامج تدريب وتغذية مخصصة لأهدافك", template: "%s — Nav Coaching" },
  description: "برامج تدريب وتغذية مخصصة لأهدافك مع الكوتش ساره: خطة منظمة، متابعة للتقدم، وتعديلات أسبوعية تناسب مستواك وظروفك.",
  openGraph: { type: "website", locale: "ar_SA", siteName: "Nav Coaching", images: ["/brand/og-logo.png"] },
  appleWebApp: { capable: true, title: "Nav Coaching", statusBarStyle: "default" },
};

export const viewport: Viewport = { themeColor: "#07142a", width: "device-width", initialScale: 1, viewportFit: "cover" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" suppressHydrationWarning>
      <head>
        {/* يفعّل حركة الظهور فقط عند توفر JavaScript؛ بدونه يظهر كل شيء مباشرة */}
        <script dangerouslySetInnerHTML={{ __html: "document.documentElement.classList.add('js');try{var t=localStorage.getItem('nav_theme');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t}catch(e){}" }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
