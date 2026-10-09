"use client";
import { useEffect } from "react";
import { usePathname } from "next/navigation";

/** يضيف حركة ظهور خفيفة للعناصر ‎.reveal‎ عند التمرير. يُلغى تلقائياً مع تفضيل تقليل الحركة (CSS). */
const AUTO = [".pub .sec-head", ".pub .card", ".pub .pcard", ".pub .table-wrap", ".pub .faq details", ".pub .steps > li", ".pub .shot", ".pub .stats", ".pub .gamers-banner"].join(", ");

export default function Reveal() {
  const pathname = usePathname();
  useEffect(() => {
    // الصفحات العامة: البطاقات والأقسام تحت الشاشة تظهر تدريجياً عند النزول (حتى لو ما عليها ‎.reveal‎)،
    // مع تأخير متدرّج بين البطاقات المتجاورة. ما فوق الشاشة لا يُخفى (بدون وميض).
    document.querySelectorAll<HTMLElement>(AUTO).forEach((el) => {
      if (el.classList.contains("reveal") || el.closest(".reveal, .hero")) return;
      if (el.getBoundingClientRect().top < window.innerHeight) return;
      const sibs = Array.from(el.parentElement?.children ?? []).filter((c) => c.matches(AUTO));
      el.style.setProperty("--d", `${(sibs.indexOf(el) % 4) * 90}ms`);
      el.classList.add("reveal");
    });
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
