"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { IconClipboard, IconClose, IconHome, IconMenu, IconReceipt, IconUser } from "@/components/Icons";

type Group = { title?: string; links: [string, string][] };

// الشريط السفلي على الجوال والآيباد العمودي: أكثر الصفحات استخداماً يومياً، والباقي في «المزيد»
const TABS: [string, string, (p: { size?: number }) => React.ReactNode][] = [
  ["/admin", "الرئيسية", IconHome], ["/admin/orders", "الطلبات", IconReceipt], ["/admin/checkins", "المراجعات", IconClipboard], ["/admin/members", "الأعضاء", IconUser],
];

/** روابط القائمة الجانبية للإدارة مع تمييز الصفحة الحالية (الأطول تطابقاً يفوز: الأكل مقابل دليل الأكل) */
export default function AdminNav({ groups }: { groups: Group[] }) {
  const path = usePathname();
  const [more, setMore] = useState(false);
  useEffect(() => setMore(false), [path]);
  useEffect(() => {
    if (!more) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setMore(false);
    document.addEventListener("keydown", esc);
    return () => document.removeEventListener("keydown", esc);
  }, [more]);
  const all = groups.flatMap((g) => g.links.map(([h]) => h)).filter((h) => h !== "/");
  const best = all.filter((h) => (h === "/admin" ? path === "/admin" : path === h || path.startsWith(h + "/"))).sort((a, b) => b.length - a.length)[0];
  const links = (g: Group) => g.links.map(([href, label]) => <Link key={href} href={href} aria-current={href === best ? "page" : undefined}>{label}</Link>);
  const inTabs = TABS.some(([h]) => h === best);
  return (
    <>
      {/* الكمبيوتر: مجموعات قابلة للطي، المفتوحة هي اللي فيها الصفحة الحالية + الطلبات */}
      <div className="nav-groups">
        {groups.map((g, i) => g.title ? (
          <details key={i} className="nav-group" open={i === 1 || g.links.some(([h]) => h === best)}>
            <summary className="nav-title">{g.title}</summary>
            {links(g)}
          </details>
        ) : <div key={i} className="nav-group">{links(g)}</div>)}
      </div>

      <div className="admin-tabs" data-testid="admin-tabs">
        {TABS.map(([href, label, Icon]) => (
          <Link key={href} href={href} aria-current={href === best ? "page" : undefined}><Icon size={22} /><span>{label}</span></Link>
        ))}
        <button type="button" aria-expanded={more} aria-controls="admin-more" aria-current={!inTabs && best ? "page" : undefined} onClick={() => setMore((v) => !v)}>
          <IconMenu size={22} /><span>المزيد</span>
        </button>
      </div>
      {more && (
        <div className="admin-sheet" id="admin-more" role="dialog" aria-modal="true" aria-label="كل صفحات الإدارة">
          <button type="button" className="sheet-backdrop" aria-label="إغلاق" onClick={() => setMore(false)} />
          <div className="sheet-body">
            <div className="sheet-head"><b>كل الصفحات</b><button type="button" className="sheet-close" aria-label="إغلاق" onClick={() => setMore(false)}><IconClose size={20} /></button></div>
            {groups.slice(1).map((g, i) => (
              <div key={i} className="sheet-group">
                {g.title && <span className="nav-title">{g.title}</span>}
                <div className="sheet-links">{links(g)}</div>
              </div>
            ))}
          </div>
        </div>
      )}
    </>
  );
}
