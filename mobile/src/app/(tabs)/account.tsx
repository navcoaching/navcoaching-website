import { router, useFocusEffect } from "expo-router";
import { useCallback, useState } from "react";
import { ScrollView, StyleSheet } from "react-native";
import { Body, Button, Card, ErrorText, Title } from "@/components/ui";
import { api, ApiError, type Me } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { loadPrefs, timeLabel, WEEKDAYS, type ReminderPrefs } from "@/lib/reminders";
import { useTracker } from "@/lib/tracker/context";

// حسابي: التذكيرات للجميع، والحساب والمتابعة مع المدربة لمن سجّل دخوله (الدخول اختياري)
export default function Account() {
  const tracker = useTracker();
  const { data: session, isPending } = authClient.useSession();
  const [me, setMe] = useState<Me | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [prefs, setPrefs] = useState<ReminderPrefs | null>(null);

  useFocusEffect(useCallback(() => {
    loadPrefs(tracker).then(setPrefs);
    if (!session) { setMe(null); return; }
    setError(null);
    api<Me>("/me").then(setMe).catch((e) => {
      if (e instanceof ApiError && e.status === 401) setMe(null);
      else setError("تعذّر تحميل حسابك. تأكد من الاتصال.");
    });
  }, [tracker, session?.user.id]));

  async function signOut() {
    setBusy(true);
    await authClient.signOut();
    setBusy(false);
    setMe(null);
  }

  const reminderText = prefs && prefs.days.length
    ? `${prefs.days.map((d) => WEEKDAYS[d - 1]).join("، ")} · ${timeLabel(prefs.hour, prefs.minute)}`
    : "بدون تذكير";

  return (
    <ScrollView contentContainerStyle={s.page} contentInsetAdjustmentBehavior="automatic">
      <Card>
        <Title>تذكير التمرين</Title>
        <Body muted>{reminderText}</Body>
        <Button title="تعديل التذكير" variant="ghost" onPress={() => router.push("/reminders")} />
      </Card>

      {!session ? (
        <Card>
          <Title>المتابعة مع الكوتش ساره</Title>
          <Body muted>متدرب مع الكوتش؟ ادخل ببريدك لتشوف برنامجك ومتابعتك. المتتبّع المجاني لا يحتاج حساباً.</Body>
          <Button title="الدخول" busy={isPending} onPress={() => router.push("/login")} />
        </Card>
      ) : (
        <>
          {error && <ErrorText>{error}</ErrorText>}
          <Card>
            <Title>{me?.user.name || "حسابي"}</Title>
            <Body muted>{session.user.email}</Body>
          </Card>
          <Card>
            <Title>المتابعة مع المدربة</Title>
            {me?.coaching ? (
              <Body>اشتراكك فعّال (طلب {me.coaching.orderNo}). برنامجك يظهر هنا في المرحلة 3.</Body>
            ) : (
              <Body muted>ما عندك اشتراك متابعة حالياً. المتتبّع المجاني متاح لك كاملاً.</Body>
            )}
          </Card>
          <Button title="تسجيل الخروج" variant="ghost" busy={busy} onPress={signOut} />
        </>
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
