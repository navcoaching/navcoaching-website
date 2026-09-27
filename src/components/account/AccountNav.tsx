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
        // الأطول تطابقاً يفوز (التغذية مقابل سجل الماكروز)
        const matches = (h: string) => { const t = h.split("#")[0]; return !h.includes("#") && (path === t || path.startsWith(t + "/")); };
        const longer = links.some((x) => x.href && x.href !== l.href && x.href.startsWith(target + "/") && matches(x.href));
        const current = !l.href.includes("#") && !longer && (l.exact ? path === target : matches(l.href));
        return (
          <Link key={l.label} href={l.href} aria-current={current ? "page" : undefined}>
            <span aria-hidden="true">{l.icon}</span> {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
