"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { langOfPath, switchPath } from "@/lib/lang";

/** رابط اللغة الأخرى لنفس الصفحة (EN في العربية، عربي في الإنجليزية) */
export default function LangSwitch({ className }: { className?: string }) {
  const path = usePathname() ?? "/";
  const lang = langOfPath(path);
  const to = lang === "en" ? "ar" : "en";
  return (
    <Link href={switchPath(path, to)} hrefLang={to} lang={to} className={className} aria-label={lang === "en" ? "النسخة العربية" : "English version"} data-testid="lang-switch">
      {lang === "en" ? "عربي" : "English"}
    </Link>
  );
}
