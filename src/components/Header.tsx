import Link from "next/link";
import Image from "next/image";
import { IconMenu, IconUser } from "./Icons";
import ThemeToggle from "./ThemeToggle";
import MobileMenu from "./MobileMenu";
import NavLinks, { type NavItem } from "./NavLinks";
import LangSwitch from "./LangSwitch";
import { href, type Lang } from "@/lib/lang";
import { t } from "@/i18n/ui";

// الهيدر ثابت (بدون قراءة الجلسة) حتى تبقى الصفحات العامة سريعة وقابلة للتخزين المؤقت.
export default function Header({ lang = "ar" }: { lang?: Lang }) {
  const u = t(lang).nav;
  const LINKS: NavItem[] = [
    { href: href(lang, "/programs"), label: u.programs },
    { href: href(lang, "/about"), label: u.about },
    { href: href(lang, "/reviews"), label: u.reviews },
    { href: href(lang, "/faq"), label: u.faq },
  ];
  const account = { href: "/account", label: u.account };
  return (
    <header className="site-header">
      <div className="wrap">
        <Link href={href(lang, "/")} className="brand" aria-label="Nav Coaching">
          <Image className="l-light" src="/brand/logo-color.webp" alt="Nav Coaching" width={150} height={34} priority />
          <Image className="l-dark" src="/brand/logo-white.webp" alt="Nav Coaching" width={150} height={34} priority />
        </Link>
        <nav className="nav" aria-label={u.menu}>
          <NavLinks links={LINKS} />
          <LangSwitch />
          <ThemeToggle />
          <Link href={account.href} className="btn btn-ghost btn-sm"><IconUser size={18} />{account.label}</Link>
          <Link href={href(lang, "/programs")} className="btn btn-sm">{u.pricing}</Link>
        </nav>
        <MobileMenu summary={<IconMenu />} label={u.openMenu}>
          <nav className="menu-panel" aria-label={u.menu}>
            <NavLinks links={LINKS} />
            <Link href={account.href}>{account.label}</Link>
            <LangSwitch />
            <ThemeToggle withLabel />
            <Link href={href(lang, "/programs")} className="btn btn-block">{u.pricing}</Link>
          </nav>
        </MobileMenu>
      </div>
    </header>
  );
}
