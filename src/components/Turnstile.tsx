"use client";
import Script from "next/script";
import { useEffect, useId, useRef } from "react";

declare global {
  interface Window { turnstile?: { render: (el: HTMLElement, o: Record<string, unknown>) => string; reset: (id?: string) => void; remove: (id: string) => void } }
}

export const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? "";

/**
 * ودجت Cloudflare Turnstile (حماية من الروبوتات). لا يُعرض إذا لم يُضبط مفتاح الموقع.
 * داخل <form> يضيف الحقل cf-turnstile-response تلقائياً؛ وonToken لمن يرسل بغير نموذج (الدخول).
 */
export default function Turnstile({ onToken, action }: { onToken?: (token: string) => void; action: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const widget = useRef<string | null>(null);
  const id = useId();
  useEffect(() => {
    if (!TURNSTILE_SITE_KEY) return;
    let tries = 0;
    const t = setInterval(() => {
      if (!window.turnstile || !ref.current) { if (++tries > 100) clearInterval(t); return; }
      clearInterval(t);
      widget.current = window.turnstile.render(ref.current, {
        sitekey: TURNSTILE_SITE_KEY, action, language: "ar", size: "flexible", theme: "auto",
        callback: (token: string) => onToken?.(token),
        "expired-callback": () => onToken?.(""),
        "error-callback": () => onToken?.(""),
      });
    }, 100);
    return () => { clearInterval(t); if (widget.current) window.turnstile?.remove(widget.current); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  if (!TURNSTILE_SITE_KEY) return null;
  return (
    <>
      <Script id={`turnstile-${id}`} src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" strategy="afterInteractive" />
      <div ref={ref} data-testid="turnstile" style={{ minHeight: 65 }} />
    </>
  );
}
