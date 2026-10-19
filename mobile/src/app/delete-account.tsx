import { router } from "expo-router";
import * as SecureStore from "expo-secure-store";
import { useState } from "react";
import { Alert, ScrollView, StyleSheet } from "react-native";
import { Body, Button, Card, ErrorText, Field, Title } from "@/components/ui";
import { authClient } from "@/lib/auth-client";
import { clearCoachingCache } from "@/lib/coaching";
import { API_URL } from "@/lib/config";

// حذف الحساب من داخل التطبيق (شرط Apple 5.1.1(v)). نهائي ويتطلب كتابة «حذف».
export default function DeleteAccount() {
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run() {
    setBusy(true); setError(null);
    try {
      const cookie = await authClient.getCookie();
      const res = await fetch(`${API_URL}/api/mobile/v1/account/delete`, {
        method: "POST", credentials: "omit",
        headers: { "Content-Type": "application/json", Accept: "application/json", ...(cookie ? { Cookie: cookie } : {}) },
        body: JSON.stringify({ confirm: confirm.trim() }),
      });
      const body = (await res.json().catch(() => ({}))) as { error?: string };
      if (!res.ok) { setError(body.error ?? "تعذّر حذف الحساب."); return; }
      // الحساب حُذف من الخادم: نمسح الجلسة المحفوظة على الجوال
      await authClient.signOut().catch(() => {});
      await Promise.all(["navcoaching_cookie", "navcoaching_session_data"].map((k) => SecureStore.deleteItemAsync(k).catch(() => {})));
      clearCoachingCache();
      Alert.alert("تم حذف حسابك", "سجل تمارينك المجاني على هذا الجوال باقٍ، وتقدر تحذفه بحذف التطبيق.");
      router.dismissTo("/");
    } catch {
      setError("تحتاج اتصالاً بالإنترنت لحذف الحساب.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Card>
        <Title>حذف الحساب نهائياً</Title>
        <Body>يُحذف حسابك وكل بياناته من خوادم Nav Coaching: الطلبات، والاستبيانات، والإيصالات، وبرامج المدربة وسجلاتها.</Body>
        <Body>إذا عندك اشتراك جارٍ فسيتوقف، ولا يمكن التراجع عن الحذف.</Body>
        <Body muted>لطلب استرداد مبلغ حسب سياسة الضمان، تواصل مع المدربة قبل الحذف.</Body>
      </Card>
      <Field label="اكتب «حذف» للتأكيد" value={confirm} onChangeText={setConfirm} autoCorrect={false} />
      {error && <ErrorText>{error}</ErrorText>}
      <Button title="احذف حسابي" busy={busy} disabled={confirm.trim() !== "حذف"} onPress={run} />
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
