"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { waIntro, waLink } from "@/lib/format";
import { IconWhatsApp } from "./Icons";

/** الصفحات التي لا يظهر فيها الشريط: الخاصة (لها شريطها)، وصفحة الباقة (فيها شريط السعر والاشتراك مع زر واتساب) */
const HIDE = /^\/(account|checkout|login|admin)(\/|$)|^\/programs\/[^/]+$/;

/** شريط سفلي ثابت على الجوال في الصفحات العامة: واتساب برسالة جاهزة، والبرامج */
export default function MobileBar({ whatsapp }: { whatsapp: string }) {
  const path = usePathname() ?? "/";
  if (HIDE.test(path)) return null;
  return (
    <nav className="mbar" aria-label="إجراءات سريعة" data-testid="mobile-bar">
      <a href={waLink(whatsapp, waIntro())} target="_blank" rel="noopener" className="mbar-wa"><IconWhatsApp size={20} />واتساب</a>
      <Link href="/programs" className="mbar-main">البرامج والأسعار</Link>
    </nav>
  );
}
