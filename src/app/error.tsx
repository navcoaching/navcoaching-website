"use client";
import { useEffect } from "react";

/** صفحة الخطأ العامة. «رمز الخطأ» يطابق السطر في سجلات الخادم (Netlify ← Logs) للتشخيص، بدون أي تفاصيل حساسة */
export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => { console.error(error); }, [error]);
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
