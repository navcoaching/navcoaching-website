"use client";
import { useEffect, useRef } from "react";
import { usePathname } from "next/navigation";

/**
 * قائمة الجوال: تُغلق تلقائياً عند اختيار رابط، أو تغيّر الصفحة، أو الضغط خارجها، أو زر Esc.
 * الاختيار نفسه (تبديل المظهر) لا يغلقها.
 */
export default function MobileMenu({ summary, children }: { summary: React.ReactNode; children: React.ReactNode }) {
  const ref = useRef<HTMLDetailsElement>(null);
  const pathname = usePathname();
  const close = () => { if (ref.current) ref.current.open = false; };

  useEffect(close, [pathname]);
  useEffect(() => {
    const onDown = (e: PointerEvent) => { if (ref.current?.open && !ref.current.contains(e.target as Node)) close(); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("pointerdown", onDown); document.removeEventListener("keydown", onKey); };
  }, []);

  return (
    <details className="menu" ref={ref}>
      <summary aria-label="فتح القائمة">{summary}</summary>
      <div onClick={(e) => { if ((e.target as HTMLElement).closest("a")) close(); }}>{children}</div>
    </details>
  );
}
