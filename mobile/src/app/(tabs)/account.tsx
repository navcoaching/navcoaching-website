import { router } from "expo-router";
import { useEffect, useState } from "react";
import { ScrollView, StyleSheet } from "react-native";
import { Body, Button, Card, ErrorText, Title } from "@/components/ui";
import { api, ApiError, type Me } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

export default function Account() {
  const [me, setMe] = useState<Me | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api<Me>("/me").then(setMe).catch((e) => {
      if (e instanceof ApiError && e.status === 401) router.replace("/login");
      else setError("تعذّر تحميل حسابك. تأكد من الاتصال.");
    });
  }, []);

  async function signOut() {
    setBusy(true);
    await authClient.signOut();
    setBusy(false);
    router.replace("/");
  }

  return (
    <ScrollView contentContainerStyle={s.page}>
      {error && <ErrorText>{error}</ErrorText>}
      {me && (
        <>
          <Card>
            <Title>{me.user.name || "حسابي"}</Title>
            <Body muted>{me.user.email}</Body>
          </Card>
          <Card>
            <Title>المتابعة مع المدربة</Title>
            {me.coaching ? (
              <Body>اشتراكك فعّال (طلب {me.coaching.orderNo}). برنامجك يظهر هنا في المرحلة 3.</Body>
            ) : (
              <Body muted>ما عندك اشتراك متابعة حالياً. المتتبّع المجاني متاح لك كاملاً.</Body>
            )}
          </Card>
        </>
      )}
      <Button title="تسجيل الخروج" variant="ghost" busy={busy} onPress={signOut} />
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
