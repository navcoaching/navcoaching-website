"use client";
import { useState } from "react";
import { authClient } from "@/lib/auth-client";

const ERR: Record<string, string> = {
  INVALID_OTP: "الرمز غير صحيح. تأكد منه وحاول مرة أخرى.",
  OTP_EXPIRED: "انتهت صلاحية الرمز. اطلب رمزاً جديداً.",
  TOO_MANY_ATTEMPTS: "محاولات كثيرة. اطلب رمزاً جديداً.",
};

export default function LoginForm({ next }: { next: string }) {
  const [step, setStep] = useState<"email" | "otp">("email");
  const [email, setEmail] = useState("");
  const [otp, setOtp] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function send(e?: React.FormEvent) {
    e?.preventDefault();
    setError("");
    const clean = email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(clean)) { setError("اكتب بريداً إلكترونياً صحيحاً."); return; }
    setBusy(true);
    const { error } = await authClient.emailOtp.sendVerificationOtp({ email: clean, type: "sign-in" });
    setBusy(false);
    if (error) { setError(error.status === 429 ? "طلبات كثيرة. انتظر دقائق ثم حاول." : "تعذّر إرسال الرمز الآن. حاول بعد قليل أو تواصل معنا على واتساب."); return; }
    setEmail(clean);
    setStep("otp");
  }

  async function verify(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    if (!/^\d{6}$/.test(otp)) { setError("الرمز 6 أرقام."); return; }
    setBusy(true);
    const { error } = await authClient.signIn.emailOtp({ email, otp });
    if (error) { setBusy(false); setError(ERR[error.code ?? ""] ?? (error.status === 429 ? "محاولات كثيرة. انتظر دقائق." : "تعذّر الدخول. حاول مرة أخرى.")); return; }
    window.location.assign(next);
  }

  return step === "email" ? (
    <form className="form" onSubmit={send} noValidate>
      <div className="field">
        <label htmlFor="email">البريد الإلكتروني</label>
        <input id="email" type="email" inputMode="email" autoComplete="email" dir="ltr" value={email}
          onChange={(e) => setEmail(e.target.value)} aria-invalid={!!error} aria-describedby="email-hint" required />
        <span id="email-hint" className="hint">نرسل لك رمز دخول من 6 أرقام. بدون كلمة مرور.</span>
      </div>
      {error && <p className="alert err" role="alert">{error}</p>}
      <button className="btn btn-block" disabled={busy}>{busy ? "جارٍ الإرسال…" : "أرسل رمز الدخول"}</button>
    </form>
  ) : (
    <form className="form" onSubmit={verify} noValidate>
      <p>أرسلنا رمزاً إلى <bdi dir="ltr"><b>{email}</b></bdi>. تأكد من مجلد الرسائل غير المرغوبة إذا ما وصل.</p>
      <div className="field">
        <label htmlFor="otp">رمز الدخول</label>
        <input id="otp" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="\d{6}" maxLength={6} dir="ltr"
          value={otp} onChange={(e) => setOtp(e.target.value.replace(/\D/g, ""))} aria-invalid={!!error} required
          style={{ letterSpacing: "0.5em", textAlign: "center", fontSize: 22 }} />
      </div>
      {error && <p className="alert err" role="alert">{error}</p>}
      <button className="btn btn-block" disabled={busy}>{busy ? "جارٍ التحقق…" : "دخول"}</button>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <button type="button" className="link-btn" onClick={() => { setStep("email"); setOtp(""); setError(""); }}>تغيير البريد</button>
        <button type="button" className="link-btn" onClick={() => send()} disabled={busy}>إعادة إرسال الرمز</button>
      </div>
    </form>
  );
}
