"use client";
import { useEffect, useState } from "react";

/** زمن انتظار المتصفح لرد الخادم (من جهاز المدربة وشبكتها)، من Navigation Timing */
export default function BrowserTiming() {
  const [v, setV] = useState<{ wait: number; load: number } | null>(null);
  useEffect(() => {
    const n = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming | undefined;
    if (n) setV({ wait: n.responseStart - n.requestStart, load: n.duration || n.responseEnd - n.startTime });
  }, []);
  const ms = (x: number) => `${Math.round(x)} مللي ثانية`;
  return (
    <>
      <div className="speed-row"><span>انتظار جهازك لرد الخادم</span><b data-testid="speed-browser-wait">{v ? ms(v.wait) : "—"}</b></div>
      <div className="speed-row"><span>تحميل الصفحة كاملة على جهازك</span><b data-testid="speed-browser-load">{v ? ms(v.load) : "—"}</b></div>
    </>
  );
}
