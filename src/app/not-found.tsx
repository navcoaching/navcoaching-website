import Link from "next/link";

export default function NotFound() {
  return (
    <main className="section" id="main">
      <div className="wrap stack center" style={{ maxWidth: 560 }}>
        <p className="eyebrow" style={{ justifyContent: "center" }}>404</p>
        <h1 style={{ fontSize: 34 }}>الصفحة غير موجودة</h1>
        <p className="muted">قد يكون الرابط قديماً، أو هذه الصفحة غير متاحة لحسابك.</p>
        <div className="row" style={{ justifyContent: "center" }}><Link className="btn" href="/">الرئيسية</Link><Link className="btn btn-ghost" href="/account">حسابي</Link></div>
      </div>
    </main>
  );
}
