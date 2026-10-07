import { router } from "expo-router";
import { ScrollView, StyleSheet } from "react-native";
import { Body, Button, Card, Title } from "@/components/ui";
import { authClient } from "@/lib/auth-client";

// الشاشة الرئيسية. المتتبّع المجاني يعمل بدون تسجيل (شرط Apple 5.1.1(v))، والحساب اختياري.
export default function Home() {
  const { data: session, isPending } = authClient.useSession();

  return (
    <ScrollView contentContainerStyle={s.page} contentInsetAdjustmentBehavior="automatic">
      <Card>
        <Title>جدولك التدريبي</Title>
        <Body muted>ابنِ جدولك، سجّل أوزانك في كل تمرين، وتابع تقدّمك أسبوعاً بأسبوع. مجاناً وبدون تسجيل.</Body>
        <Body muted>(المرحلة 1: قيد البناء)</Body>
      </Card>

      <Card>
        <Title>حسابك</Title>
        {session ? (
          <>
            <Body>مرحباً {session.user.name || session.user.email}</Body>
            <Button title="حسابي" variant="ghost" onPress={() => router.push("/account")} />
          </>
        ) : (
          <>
            <Body muted>متدرب مع الكوتش ساره؟ ادخل ببريدك لتشوف برنامجك ومتابعتك.</Body>
            <Button title="الدخول" busy={isPending} onPress={() => router.push("/login")} />
          </>
        )}
      </Card>
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
