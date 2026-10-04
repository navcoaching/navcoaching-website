"use client";
import Script from "next/script";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";

const KEY = "nav_analytics_consent";
/** صفحات فيها بيانات المتدرب (صحة، طلبات، دفع): لا يُحمَّل عليها قياس الزيارات أبداً */
const PRIVATE = /^\/(account|checkout|login|admin|api)(\/|$)/;

/**
 * Google Analytics 4: يعمل فقط بعد موافقة الزائر، وفقط على الصفحات العامة.
 * الزائر يرى شريطاً صغيراً مرة واحدة (موافق / لا)، والاختيار يُحفظ على جهازه.
 */
export default function Analytics({ id }: { id: string }) {
  const path = usePathname() ?? "/";
  const [consent, setConsent] = useState<"yes" | "no" | null | undefined>(undefined);
  const isPrivate = PRIVATE.test(path);

  useEffect(() => {
    try { const v = localStorage.getItem(KEY); setConsent(v === "yes" || v === "no" ? v : null); } catch { setConsent(null); }
  }, []);
  // لو انتقل الزائر من صفحة عامة لصفحة خاصة داخل التطبيق، نوقف الإرسال فوراً
  useEffect(() => {
    (window as unknown as Record<string, unknown>)[`ga-disable-${id}`] = isPrivate || consent !== "yes";
  }, [id, isPrivate, consent]);

  const choose = (v: "yes" | "no") => { try { localStorage.setItem(KEY, v); } catch { /* التخزين غير متاح */ } setConsent(v); };
  const active = consent === "yes" && !isPrivate;
  return (
    <>
      {active && (
        <>
          <Script src={`https://www.googletagmanager.com/gtag/js?id=${id}`} strategy="afterInteractive" />
          <Script id="ga-init" strategy="afterInteractive">{`window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','${id}',{anonymize_ip:true,allow_google_signals:false,allow_ad_personalization_signals:false});`}</Script>
        </>
      )}
      {consent === null && !isPrivate && (
        <div className="consent-bar" role="region" aria-label="ملفات تعريف الارتباط" data-testid="consent-bar">
          <p className="small">نستخدم Google Analytics لقياس زيارات الموقع وتحسينه، بدون ربطها ببياناتك الصحية أو حسابك. توافق؟</p>
          <div className="row" style={{ gap: 8 }}>
            <button type="button" className="btn btn-sm" onClick={() => choose("yes")}>موافق</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => choose("no")}>لا، شكراً</button>
          </div>
        </div>
      )}
    </>
  );
}
