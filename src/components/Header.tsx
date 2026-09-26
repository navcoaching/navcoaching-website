import Link from "next/link";
import Image from "next/image";
import { IconMenu, IconUser } from "./Icons";
import ThemeToggle from "./ThemeToggle";
import MobileMenu from "./MobileMenu";
import NavLinks, { type NavItem } from "./NavLinks";

const LINKS: NavItem[] = [
  { href: "/programs", label: "البرامج" },
  { href: "/#how", label: "كيف أشترك؟" },
  { href: "/about", label: "عن المدربة" },
  { href: "/reviews", label: "التقييمات" },
  { href: "/faq", label: "الأسئلة الشائعة" },
  { href: "/free-plans", label: "الجداول المجانية", highlight: true },
  { href: "/calculator", label: "حاسبة السعرات", highlight: true },
];

// الهيدر ثابت (بدون قراءة الجلسة) حتى تبقى الصفحات العامة سريعة وقابلة للتخزين المؤقت.
export default function Header() {
  const account = { href: "/account", label: "حسابي" };
  return (
    <header className="site-header">
      <div className="wrap">
        <Link href="/" className="brand" aria-label="Nav Coaching — الرئيسية">
          <Image className="l-light" src="/brand/logo-color.webp" alt="Nav Coaching" width={150} height={34} priority />
          <Image className="l-dark" src="/brand/logo-white.webp" alt="Nav Coaching" width={150} height={34} priority />
        </Link>
        <nav className="nav" aria-label="القائمة الرئيسية">
          <NavLinks links={LINKS} />
          <ThemeToggle />
          <Link href={account.href} className="btn btn-ghost btn-sm"><IconUser size={18} />{account.label}</Link>
          <Link href="/programs" className="btn btn-sm">ابدأ الآن</Link>
        </nav>
        <MobileMenu summary={<IconMenu />}>
          <nav className="menu-panel" aria-label="القائمة">
            <NavLinks links={LINKS} />
            <Link href={account.href}>{account.label}</Link>
            <ThemeToggle withLabel />
            <Link href="/programs" className="btn btn-block">ابدأ الآن</Link>
          </nav>
        </MobileMenu>
      </div>
    </header>
  );
}
