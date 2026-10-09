import type { Metadata } from "next";
import Link from "next/link";
import LoginForm, { SignedInAs } from "./LoginForm";
import { getCurrentUser, safeNext } from "@/lib/session";

export const metadata: Metadata = { title: "الدخول", robots: { index: false } };

export default async function Login({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const next = safeNext((await searchParams).next);
  const user = await getCurrentUser();
  return (
    <section className="section">
      <div className="wrap" style={{ maxWidth: 520 }}>
        <div className="card stack" style={{ ["--space" as string]: "18px" }}>
          <span className="eyebrow">حسابك في Nav Coaching</span>
          <h1 style={{ fontSize: 30 }}>الدخول أو إنشاء حساب</h1>
          <p className="muted">نفس الخطوة للاثنين: اكتب بريدك ويوصلك رمز. من حسابك تتابع طلباتك وترفع الإيصال وتستلم ملفاتك.</p>
          {user ? <SignedInAs name={user.name || user.email} email={user.email} next={next} /> : <LoginForm next={next} />}
          <p className="small muted">بالدخول أنت توافق على <Link href="/policies#terms">الشروط</Link> و<Link href="/policies#privacy">سياسة الخصوصية</Link>.</p>
        </div>
      </div>
    </section>
  );
}
