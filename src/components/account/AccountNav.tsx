"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef } from "react";
import { IconBook, IconClipboard, IconDumbbell, IconReceipt, IconSalad, IconTrend } from "../Icons";

// أيقونات خطية موحدة بلون الهوية (بدل الإيموجي)
const ICONS = { orders: IconReceipt, training: IconDumbbell, progress: IconTrend, nutrition: IconSalad, checkin: IconClipboard, guide: IconBook } as const;
export type AccountIcon = keyof typeof ICONS;

// daily: false = يظهر في القائمة الجانبية فقط، ويختفي من الشريط السفلي على الجوال (نكتفي فيه بصفحات الاستخدام اليومي)
export type AccountLink = { href: string | null; label: string; icon: AccountIcon; exact?: boolean; daily?: false };

/** قائمة حساب المتدرب: جانبية على الشاشات الكبيرة، وشريط أفقي على الجوال */
export default function AccountNav({ links }: { links: AccountLink[] }) {
  const path = usePathname();
  const nav = useRef<HTMLElement>(null);
  // على الجوال القائمة شريط أفقي: الصفحة الحالية تظهر في الوسط بدل ما تكون مقصوصة على الطرف
  useEffect(() => {
    const el = nav.current;
    const cur = el?.querySelector<HTMLElement>('[aria-current="page"]');
    if (!el || !cur || el.scrollWidth <= el.clientWidth) return;
    el.scrollLeft += cur.getBoundingClientRect().left - el.getBoundingClientRect().left - (el.clientWidth - cur.offsetWidth) / 2;
  }, [path]);
  return (
    <nav ref={nav} className="account-side" aria-label="حسابي" data-testid="account-nav">
      {links.map((l) => {
        const Icon = ICONS[l.icon];
        if (!l.href) {
          return <span key={l.label} className={`off${l.daily === false ? " not-daily" : ""}`} title="يظهر بعد تجهيز برنامجك"><span className="nav-ico" aria-hidden="true"><Icon size={18} /></span> {l.label}</span>;
        }
        const target = l.href.split("#")[0];
        // الأطول تطابقاً يفوز (التغذية مقابل سجل الماكروز)
        const matches = (h: string) => { const t = h.split("#")[0]; return !h.includes("#") && (path === t || path.startsWith(t + "/")); };
        const longer = links.some((x) => x.href && x.href !== l.href && x.href.startsWith(target + "/") && matches(x.href));
        const current = !l.href.includes("#") && !longer && (l.exact ? path === target : matches(l.href));
        return (
          <Link key={l.label} href={l.href} aria-current={current ? "page" : undefined} className={l.daily === false ? "not-daily" : undefined}>
            <span className="nav-ico" aria-hidden="true"><Icon size={18} /></span> {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
