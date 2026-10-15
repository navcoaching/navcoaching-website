import { router } from "expo-router";
import { useState } from "react";
import { KeyboardAvoidingView, Platform, ScrollView, StyleSheet } from "react-native";
import { Body, Button, ErrorText, Field } from "@/components/ui";
import { authClient } from "@/lib/auth-client";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// نفس دخول الموقع: البريد ← رمز من 6 أرقام. الحساب يُنشأ تلقائياً عند أول دخول.
export default function Login() {
  const [email, setEmail] = useState("");
  const [otp, setOtp] = useState("");
  const [step, setStep] = useState<"email" | "code">("email");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function sendCode() {
    const e = email.trim().toLowerCase();
    if (!EMAIL_RE.test(e)) return setError("اكتب بريداً صحيحاً.");
    setBusy(true); setError(null);
    const { error: err } = await authClient.emailOtp.sendVerificationOtp({ email: e, type: "sign-in" });
    setBusy(false);
    if (err) return setError(err.status === 429 ? "طلبات كثيرة. انتظر دقائق ثم حاول." : "تعذّر إرسال الرمز. تأكد من الاتصال وحاول مرة ثانية.");
    setEmail(e); setStep("code");
  }

  async function verify() {
    if (!/^\d{6}$/.test(otp)) return setError("الرمز 6 أرقام.");
    setBusy(true); setError(null);
    const { error: err } = await authClient.signIn.emailOtp({ email, otp });
    setBusy(false);
    if (err) return setError("الرمز غير صحيح أو انتهت صلاحيته.");
    router.back();
  }

  return (
    <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === "ios" ? "padding" : undefined}>
      <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
        {step === "email" ? (
          <>
            <Body muted>اكتب بريدك ويوصلك رمز دخول من 6 أرقام. بدون كلمة مرور.</Body>
            <Field label="البريد الإلكتروني" value={email} onChangeText={setEmail} autoCapitalize="none" autoComplete="email"
              keyboardType="email-address" textContentType="emailAddress" returnKeyType="send" onSubmitEditing={sendCode}
              style={{ textAlign: "left", writingDirection: "ltr" }} />
            {error && <ErrorText>{error}</ErrorText>}
            <Button title="أرسل رمز الدخول" busy={busy} onPress={sendCode} />
          </>
        ) : (
          <>
            <Body muted>أرسلنا الرمز إلى {email}</Body>
            <Field label="رمز الدخول" value={otp} onChangeText={(v) => setOtp(v.replace(/\D/g, "").slice(0, 6))}
              keyboardType="number-pad" textContentType="oneTimeCode" autoComplete="one-time-code" maxLength={6}
              returnKeyType="done" onSubmitEditing={verify} style={{ textAlign: "center", letterSpacing: 8, fontSize: 24 }} />
            {error && <ErrorText>{error}</ErrorText>}
            <Button title="دخول" busy={busy} onPress={verify} />
            <Button title="تغيير البريد" variant="ghost" onPress={() => { setStep("email"); setOtp(""); setError(null); }} />
          </>
        )}
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
