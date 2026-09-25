"use client";

export default function Error({ reset }: { error: Error; reset: () => void }) {
  return (
    <main className="section" id="main">
      <div className="wrap stack center" style={{ maxWidth: 560 }}>
        <h1 style={{ fontSize: 30 }}>صار خطأ غير متوقع</h1>
        <p className="muted">حاول مرة أخرى. إذا تكرر، تواصل معنا على واتساب.</p>
        <div className="row" style={{ justifyContent: "center" }}><button className="btn" onClick={reset}>إعادة المحاولة</button></div>
      </div>
    </main>
  );
}
