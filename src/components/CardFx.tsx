"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";

// بطاقات الصفحات العامة: عند الضغط تلمع وتدور حول نفسها 360°.
// بطاقات البرامج روابط: تكمل الحركة (0.7 ث) ثم تنتقل لصفحة الباقة.
// مع تفضيل «تقليل الحركة» يُلغى الدوران ويبقى اللمعان، والروابط تنتقل فوراً.
const SPIN = ".pub .card.feature, .pub .steps > li, .pub .pcard";

export default function CardFx() {
  const router = useRouter();
  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    const onClick = (e: MouseEvent) => {
      const t = e.target as Element | null;
      if (!t || t.closest("button, input, select, textarea, summary")) return;
      const el = t.closest<HTMLElement>(SPIN);
      if (!el) return;
      const link = el instanceof HTMLAnchorElement ? el : null;
      // فتح في تبويب جديد أو بزر الماوس الأوسط: نترك المتصفح يتصرف عادي
      if (link && (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || link.target === "_blank")) return;
      el.classList.add("fx");
      const shine = document.createElement("span");
      shine.className = "fx-shine";
      shine.setAttribute("aria-hidden", "true");
      el.appendChild(shine);
      shine.addEventListener("animationend", () => shine.remove(), { once: true });
      if (reduced.matches) return;
      // نلتقط الضغط قبل Link (مرحلة capture) حتى لا ينتقل قبل انتهاء الحركة
      if (link) { e.preventDefault(); e.stopPropagation(); }
      el.classList.remove("fx-spin");
      void el.offsetWidth; // إعادة تشغيل الحركة عند الضغط المتكرر
      el.classList.add("fx-spin");
      const done = (ev: AnimationEvent) => {
        if (ev.target !== el) return;
        el.removeEventListener("animationend", done);
        el.classList.remove("fx-spin");
        if (link) router.push(link.getAttribute("href") ?? "/");
      };
      el.addEventListener("animationend", done);
    };
    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
  }, [router]);
  return null;
}
