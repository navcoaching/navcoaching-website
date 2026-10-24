"use client";
import { useEffect } from "react";
import { unstable_isUnrecognizedActionError } from "next/navigation";

/** صفحة الخطأ العامة. «رمز الخطأ» يطابق السطر في سجلات الخادم (Netlify ← Logs) للتشخيص، بدون أي تفاصيل حساسة */
export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  // الصفحة مفتوحة من نسخة قديمة من الموقع (انتشر تحديث بعد فتحها)، فأزرار الحفظ فيها ما عاد يعرفها الخادم.
  // الحل: إعادة تحميل الصفحة مرة واحدة تلقائياً لتأخذ النسخة الجديدة (مع حماية من تكرار التحميل).
  const stale = error.name === "UnrecognizedActionError" || unstable_isUnrecognizedActionError(error as unknown);
  useEffect(() => {
    console.error(error);
    if (!stale) return;
    try {
      const k = `reloaded:${location.pathname}`;
      const last = Number(sessionStorage.getItem(k) ?? 0);
      if (Date.now() - last < 60_000) return;
      sessionStorage.setItem(k, String(Date.now()));
    } catch { /* التخزين غير متاح: نكمل بإعادة التحميل */ }
    const t = setTimeout(() => location.reload(), 1800);
    return () => clearTimeout(t);
  }, [error, stale]);
  if (stale) {
    return (
      <main className="section" id="main">
        <div className="wrap stack center" style={{ maxWidth: 560 }} data-testid="stale-version">
          <h1 style={{ fontSize: 28 }}>تحدّث الموقع للتو</h1>
          <p className="muted">الصفحة كانت مفتوحة من نسخة سابقة، فما انحفظ آخر إجراء. نعيد تحميلها الآن، وبعدها كرّر العملية (وإذا كان رفع ملف، اختاريه من جديد).</p>
          <div className="row" style={{ justifyContent: "center" }}><button className="btn" onClick={() => location.reload()}>إعادة تحميل الصفحة</button></div>
        </div>
      </main>
    );
  }
  const code = error.digest ?? (error.name && error.name !== "Error" ? error.name : null);
  return (
    <main className="section" id="main">
      <div className="wrap stack center" style={{ maxWidth: 560 }}>
        <h1 style={{ fontSize: 30 }}>صار خطأ غير متوقع</h1>
        <p className="muted">حاول مرة أخرى. إذا تكرر، تواصل معنا على واتساب.</p>
        {code && <p className="small muted" data-testid="error-code">رمز الخطأ: <bdi dir="ltr" className="num">{code}</bdi></p>}
        <div className="row" style={{ justifyContent: "center" }}><button className="btn" onClick={reset}>إعادة المحاولة</button></div>
      </div>
    </main>
  );
}
