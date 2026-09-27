"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

export type AccountLink = { href: string | null; label: string; icon: string; exact?: boolean };

/** قائمة حساب المتدرب: جانبية على الشاشات الكبيرة، وشريط أفقي على الجوال */
export default function AccountNav({ links }: { links: AccountLink[] }) {
  const path = usePathname();
  return (
    <nav className="account-side" aria-label="حسابي" data-testid="account-nav">
      {links.map((l) => {
        if (!l.href) {
          return <span key={l.label} className="off" title="يظهر بعد تجهيز برنامجك"><span aria-hidden="true">{l.icon}</span> {l.label}</span>;
        }
        const target = l.href.split("#")[0];
        const current = !l.href.includes("#") && (l.exact ? path === target : path === target || path.startsWith(target + "/"));
        return (
          <Link key={l.label} href={l.href} aria-current={current ? "page" : undefined}>
            <span aria-hidden="true">{l.icon}</span> {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
