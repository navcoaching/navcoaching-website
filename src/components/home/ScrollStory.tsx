"use client";
import { useEffect, useRef } from "react";

/**
 * خط القصة بطول الصفحة الرئيسية (مأخوذ من lumofy.ai): خط عمودي بجانب حافة النص يمتلئ حتى منتصف الشاشة مع التمرير،
 * وعلامة عند كل عنوان قسم ‎[data-story]‎ تضيء عند الوصول له، والعناوين والنصوص ‎[data-fill]‎ تمتلئ لوناً من اليمين.
 * بدون جافاسكربت أو مع تقليل الحركة أو عند الطباعة يظهر النص كاملاً (CSS).
 */
export default function ScrollStory() {
  const railRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const rail = railRef.current;
    const root = rail?.parentElement;
    if (!rail || !root) return;
    const heads = Array.from(root.querySelectorAll<HTMLElement>("[data-story]"));
    const texts = Array.from(root.querySelectorAll<HTMLElement>("[data-story], [data-fill]"));
    if (heads.length < 2) return;
    const fill = rail.querySelector<HTMLElement>(".fill")!;
    const dots = heads.map(() => rail.appendChild(document.createElement("i")));
    root.classList.add("story-on");

    let top = 0, len = 0, marks: number[] = [], raf = 0;
    // مواقع العلامات وطول الخط: تتغير فقط مع تغيّر المقاسات (خطوط، صور، عرض الشاشة)
    const measure = () => {
      const r = root.getBoundingClientRect();
      const wrap = heads[0].closest(".wrap") ?? heads[0];
      const w = wrap.getBoundingClientRect();
      const pad = parseFloat(getComputedStyle(wrap).paddingRight) || 0;
      // في الفراغ الجانبي يمين النص: بعيد عنه 28px إذا اتسع الفراغ، وإلا في منتصف الهامش (الجوال)
      const gap = pad + (r.right - w.right) > 64 ? 28 : pad / 2;
      rail.style.left = `${w.right - pad + gap - r.left}px`;
      marks = heads.map((h) => h.getBoundingClientRect().top - r.top + 0.62 * parseFloat(getComputedStyle(h).fontSize));
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
      const r = root.getBoundingClientRect();
      const reach = Math.max(0, Math.min(len, vh * 0.5 - r.top - top));
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
      root.classList.remove("story-on");
    };
  }, []);

  return <div ref={railRef} className="v3-story" aria-hidden="true"><i className="fill" /></div>;
}
