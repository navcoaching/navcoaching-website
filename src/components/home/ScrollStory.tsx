"use client";
import { useEffect, useRef } from "react";
import { usePathname } from "next/navigation";

// عناوين الصفحات الداخلية (بدون data-story): عناوين الأقسام فقط، لا عناوين البطاقات والأسئلة والنماذج
const AUTO = ".pub:not(.v3) .section h2";
const SKIP = ".card, .pcard, .review, details, form, .page-hero";

/**
 * خط القصة بطول الصفحة (مأخوذ من lumofy.ai): خط عمودي بجانب حافة النص يمتلئ حتى منتصف الشاشة مع التمرير،
 * وعلامة عند كل عنوان قسم تضيء عند الوصول له، والعناوين والنصوص ‎[data-fill]‎ تمتلئ لوناً من اليمين.
 * الرئيسية تحدد عناوينها بـ ‎[data-story]‎، والصفحات الداخلية تُلتقط عناوين أقسامها تلقائياً (عنوانان على الأقل).
 * بدون جافاسكربت أو مع تقليل الحركة أو عند الطباعة يظهر النص كاملاً (CSS).
 */
export default function ScrollStory() {
  const railRef = useRef<HTMLDivElement>(null);
  const pathname = usePathname();

  useEffect(() => {
    const rail = railRef.current;
    const root = document.querySelector<HTMLElement>("main .pub");
    if (!rail || !root) return;
    const added: HTMLElement[] = [];
    let heads = Array.from(root.querySelectorAll<HTMLElement>("[data-story]"));
    if (!heads.length) {
      heads = Array.from(root.querySelectorAll<HTMLElement>(AUTO)).filter((h) => !h.closest(SKIP) && h.offsetParent);
      for (const h of heads) {
        h.setAttribute("data-story", ""); added.push(h);
        const p = h.nextElementSibling;
        if (p instanceof HTMLParagraphElement) { p.setAttribute("data-fill", ""); added.push(p); }
      }
    }
    if (heads.length < 2) { added.forEach((e) => { e.removeAttribute("data-story"); e.removeAttribute("data-fill"); }); return; }
    const texts = Array.from(root.querySelectorAll<HTMLElement>("[data-story], [data-fill]"));
    const fill = rail.querySelector<HTMLElement>(".fill")!;
    const dots = heads.map(() => rail.appendChild(document.createElement("i")));
    root.classList.add("story-on");
    rail.hidden = false;

    // المواقع نسبةً لأقرب أب موضَّع للخط (الصفحة نفسها عادةً)
    const base = () => (rail.offsetParent ?? document.documentElement).getBoundingClientRect();
    let top = 0, len = 0, marks: number[] = [], raf = 0;
    // مواقع العلامات وطول الخط: تتغير فقط مع تغيّر المقاسات (خطوط، صور، عرض الشاشة)
    const measure = () => {
      const b = base();
      // حافة النص اليمنى الأبعد بين الأقسام (بعضها أضيق من بعض)، ثم الخط في الفراغ الجانبي يمينها:
      // بعيد عنها 28px إذا اتسع الفراغ، وإلا في منتصف الهامش (الجوال)
      let edge = 0, pad = 0;
      for (const h of heads) {
        const wrap = h.closest(".wrap") ?? h;
        const p = parseFloat(getComputedStyle(wrap).paddingRight) || 0;
        const e = wrap.getBoundingClientRect().right - p;
        if (e > edge) { edge = e; pad = p; }
      }
      const gap = document.documentElement.clientWidth - edge > 64 ? 28 : pad / 2;
      rail.style.left = `${edge + gap - b.left}px`;
      marks = heads.map((h) => h.getBoundingClientRect().top - b.top + 0.62 * parseFloat(getComputedStyle(h).fontSize));
      top = marks[0];
      len = marks[marks.length - 1] - top;
      rail.style.top = `${top}px`;
      rail.style.height = `${len}px`;
      dots.forEach((d, i) => { d.style.top = `${marks[i] - top}px`; });
      update();
    };
    const update = () => {
      raf = 0;
      const vh = window.innerHeight;
      const reach = Math.max(0, Math.min(len, vh * 0.5 - base().top - top));
      fill.style.transform = `scaleY(${len ? reach / len : 0})`;
      let cur = -1;
      marks.forEach((m, i) => { if (m - top <= reach + 1) cur = i; });
      dots.forEach((d, i) => { d.classList.toggle("in", i <= cur); d.classList.toggle("now", i === cur); });
      for (const t of texts) {
        const p = (vh * 0.82 - t.getBoundingClientRect().top) / (vh * 0.42);
        t.style.setProperty("--rev", Math.min(1, Math.max(0, p)).toFixed(3));
      }
    };
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(update); };
    const ro = new ResizeObserver(measure);
    ro.observe(root);
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", measure);
    measure();
    return () => {
      ro.disconnect();
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", measure);
      if (raf) cancelAnimationFrame(raf);
      dots.forEach((d) => d.remove());
      added.forEach((e) => { e.removeAttribute("data-story"); e.removeAttribute("data-fill"); });
      root.classList.remove("story-on");
      rail.hidden = true;
    };
  }, [pathname]);

  return <div ref={railRef} className="v3-story" aria-hidden="true" hidden><i className="fill" /></div>;
}
