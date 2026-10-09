"use client";
import { useEffect, useState } from "react";
import Link from "next/link";

type BIP = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: "accepted" | "dismissed" }> };
const KEY = "nav_install_dismissed";

/** شريط «ثبّت التطبيق»: زر مباشر على أندرويد/كروم، ورابط للخطوات على الآيفون. يختفي إذا كان مثبّتاً أو أُغلق */
export default function InstallPrompt() {
  const [mode, setMode] = useState<"none" | "android" | "ios">("none");
  const [evt, setEvt] = useState<BIP | null>(null);

  useEffect(() => {
    let dismissed = false;
    try { dismissed = localStorage.getItem(KEY) === "1"; } catch {}
    const standalone = window.matchMedia("(display-mode: standalone)").matches || (navigator as { standalone?: boolean }).standalone === true;
    if (dismissed || standalone) return;
    const ua = navigator.userAgent;
    const ios = /iPhone|iPad|iPod/.test(ua) || (ua.includes("Macintosh") && navigator.maxTouchPoints > 1);
    if (ios) { setMode("ios"); return; }
    const onPrompt = (e: Event) => { e.preventDefault(); setEvt(e as BIP); setMode("android"); };
    const onInstalled = () => setMode("none");
    window.addEventListener("beforeinstallprompt", onPrompt);
    window.addEventListener("appinstalled", onInstalled);
    return () => { window.removeEventListener("beforeinstallprompt", onPrompt); window.removeEventListener("appinstalled", onInstalled); };
  }, []);

  const close = () => { try { localStorage.setItem(KEY, "1"); } catch {} setMode("none"); };
  if (mode === "none") return null;
  return (
    <div className="install-bar" role="region" aria-label="تثبيت التطبيق" data-testid="install-bar">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/icons/icon-192.png" alt="" width={40} height={40} />
      <div className="install-bar-text">
        <b>ثبّت تطبيق Nav على جوالك</b>
        <span className="small">يفتح أسرع بملء الشاشة، ومعه إشعارات المراجعة وردود المدربة.</span>
      </div>
      {mode === "android" && evt ? (
        <button type="button" className="btn btn-sm btn-cyan" onClick={async () => { await evt.prompt(); const c = await evt.userChoice; if (c.outcome === "accepted") setMode("none"); }}>ثبّت</button>
      ) : (
        <Link className="btn btn-sm btn-cyan" href="/install">الطريقة</Link>
      )}
      <button type="button" className="install-bar-x" onClick={close} aria-label="إغلاق">×</button>
    </div>
  );
}
