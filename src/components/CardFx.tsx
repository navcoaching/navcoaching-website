"use client";
import { useEffect } from "react";

// بطاقات الصفحات العامة: عند الضغط تلمع وتدور حول نفسها 360°.
// بطاقات البرامج روابط تنقل لصفحة الباقة، فتلمع فقط (الدوران ينقطع بالانتقال).
// مع تفضيل «تقليل الحركة» يُلغى الدوران ويبقى اللمعان (CSS).
const SPIN = ".pub .card.feature, .pub .steps > li";
const SHINE = ".pub .pcard";

export default function CardFx() {
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      const t = e.target as Element | null;
      if (!t || t.closest("button, input, select, textarea, summary")) return;
      const spin = t.closest<HTMLElement>(SPIN);
      const el = spin ?? t.closest<HTMLElement>(SHINE);
      if (!el) return;
      el.classList.add("fx");
      const shine = document.createElement("span");
      shine.className = "fx-shine";
      shine.setAttribute("aria-hidden", "true");
      el.appendChild(shine);
      shine.addEventListener("animationend", () => shine.remove(), { once: true });
      if (spin) {
        spin.classList.remove("fx-spin");
        void spin.offsetWidth; // إعادة تشغيل الحركة عند الضغط المتكرر
        spin.classList.add("fx-spin");
        spin.addEventListener("animationend", (ev) => { if (ev.target === spin) spin.classList.remove("fx-spin"); });
      }
    };
    document.addEventListener("click", onClick);
    return () => document.removeEventListener("click", onClick);
  }, []);
  return null;
}
