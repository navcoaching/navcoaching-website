"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

type Group = { title?: string; links: [string, string][] };

/** روابط القائمة الجانبية للإدارة مع تمييز الصفحة الحالية (الأطول تطابقاً يفوز: الأكل مقابل دليل الأكل) */
export default function AdminNav({ groups }: { groups: Group[] }) {
  const path = usePathname();
  const all = groups.flatMap((g) => g.links.map(([h]) => h)).filter((h) => h !== "/");
  const best = all.filter((h) => (h === "/admin" ? path === "/admin" : path === h || path.startsWith(h + "/"))).sort((a, b) => b.length - a.length)[0];
  return groups.map((g, i) => (
    <div key={i} className="nav-group" role={g.title ? "group" : undefined} aria-labelledby={g.title ? `nav-g${i}` : undefined}>
      {g.title && <span className="nav-title" id={`nav-g${i}`}>{g.title}</span>}
      {g.links.map(([href, label]) => <Link key={href} href={href} aria-current={href === best ? "page" : undefined}>{label}</Link>)}
    </div>
  ));
}
