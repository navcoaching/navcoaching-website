"use client";
import { useEffect } from "react";
import { usePathname } from "next/navigation";

/** يضيف حركة ظهور خفيفة للعناصر ‎.reveal‎ عند التمرير. يُلغى تلقائياً مع تفضيل تقليل الحركة (CSS). */
export default function Reveal() {
  const pathname = usePathname();
  useEffect(() => {
    const els = Array.from(document.querySelectorAll<HTMLElement>(".reveal:not(.in)"));
    if (!("IntersectionObserver" in window)) { els.forEach((e) => e.classList.add("in")); return; }
    const io = new IntersectionObserver((entries) => {
      for (const en of entries) if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); }
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    els.forEach((e) => io.observe(e));
    // عند الطباعة يظهر كل المحتوى
    const all = () => els.forEach((e) => e.classList.add("in"));
    window.addEventListener("beforeprint", all);
    return () => { io.disconnect(); window.removeEventListener("beforeprint", all); };
  }, [pathname]);
  return null;
}
