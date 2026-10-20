import type { Metadata } from "next";

export const metadata: Metadata = { title: "لا يوجد اتصال", robots: { index: false } };

/** تظهر من التطبيق المثبّت عند انقطاع الإنترنت (Service Worker). ثابتة وبدون بيانات. */
export default function Offline() {
  return (
    <main className="offline-page">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/icons/icon-192.png" alt="" width={72} height={72} />
      <h1>لا يوجد اتصال بالإنترنت</h1>
      <p>حسابك وبرنامجك يحتاجون اتصال. تأكد من الشبكة وحاول مرة ثانية.</p>
      <a className="btn" href="/account">إعادة المحاولة</a>
    </main>
  );
}
