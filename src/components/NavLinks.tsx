"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

export type NavItem = { href: string; label: string; highlight?: boolean };

/** روابط القائمة مع تمييز الصفحة الحالية (aria-current) */
export default function NavLinks({ links }: { links: NavItem[] }) {
  const path = usePathname();
  return links.map((l) => {
    const current = !l.href.includes("#") && (path === l.href || path.startsWith(l.href + "/"));
    return (
      <Link key={l.href} href={l.href} className={l.highlight ? "nav-hl" : undefined} aria-current={current ? "page" : undefined}>
        {l.label}
      </Link>
    );
  });
}
