import "@fontsource-variable/readex-pro";
import "@fontsource/ibm-plex-sans-arabic/400.css";
import "@fontsource/ibm-plex-sans-arabic/500.css";
import "@fontsource/ibm-plex-sans-arabic/600.css";
import "@fontsource/ibm-plex-sans-arabic/700.css";
import "@/app/globals.css";
import SwRegister from "@/components/SwRegister";
import { THEME_SCRIPT } from "@/lib/theme-script";
import { dirOf, type Lang } from "@/lib/lang";

/** الغلاف المشترك لكل تخطيط جذري (الموقع بلغتيه، ولوحة الإدارة) */
export default function RootHtml({ lang, children }: { lang: Lang; children: React.ReactNode }) {
  return (
    <html lang={lang} dir={dirOf(lang)} suppressHydrationWarning>
      <head>
        {/* يفعّل حركة الظهور فقط عند توفر JavaScript؛ بدونه يظهر كل شيء مباشرة */}
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body>{children}<SwRegister /></body>
    </html>
  );
}
