"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { waIntro, waLink } from "@/lib/format";
import { href, langOfPath } from "@/lib/lang";
import { t } from "@/i18n/ui";
import { IconWhatsApp } from "./Icons";

/** الصفحات التي لا يظهر فيها الشريط: الخاصة (لها شريطها)، وصفحة الباقة (فيها شريط السعر والاشتراك مع زر واتساب) */
const HIDE = /^\/(account|checkout|login|admin)(\/|$)|^(\/en)?\/programs\/[^/]+$/;

/** شريط سفلي ثابت على الجوال في الصفحات العامة: واتساب برسالة جاهزة، والبرامج */
export default function MobileBar({ whatsapp }: { whatsapp: string }) {
  const path = usePathname() ?? "/";
  if (HIDE.test(path)) return null;
  const lang = langOfPath(path);
  const u = t(lang).bar;
  return (
    <nav className="mbar" aria-label={u.aria} data-testid="mobile-bar">
      <a href={waLink(whatsapp, waIntro())} target="_blank" rel="noopener" className="mbar-wa"><IconWhatsApp size={20} />{u.whatsapp}</a>
      <Link href={href(lang, "/programs")} className="mbar-main">{u.programs}</Link>
    </nav>
  );
}
