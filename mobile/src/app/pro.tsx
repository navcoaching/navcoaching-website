import { router } from "expo-router";
import { ScrollView } from "react-native";
import { Body, Button, Card, Title } from "@/components/ui";
import { authClient } from "@/lib/auth-client";
import { useCoachAlts } from "@/lib/pro";

// «ناف برو». الاشتراك من داخل التطبيق يكون عبر Apple فقط (البند 3.1.1)؛ لا روابط أو أسعار دفع خارجية هنا.
export default function Pro() {
  const { data: session } = authClient.useSession();
  const { pro } = useCoachAlts();
  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 16, paddingBottom: 48 }}>
      <Card>
        <Title>⭐ بدائل الكوتش ساره</Title>
        <Body>الجهاز مشغول؟ التمرين ما يناسبك أو يضايقك؟ بدل ما تختار أي تمرين لنفس العضلة، تشوف البدائل اللي اختارتها الكوتش بنفسها لكل تمرين، وتبدّل بضغطة في برنامجك أو وسط التمرين.</Body>
        <Body muted>القائمة تتحدّث كل ما أضافت الكوتش بدائل جديدة.</Body>
      </Card>
      {pro ? (
        <Card><Title>✓ «ناف برو» مفعّل لك</Title></Card>
      ) : (
        <Card>
          <Body>الاشتراك في «ناف برو» من داخل التطبيق متاح قريباً.</Body>
          <Body muted>مشترك في باقة متابعة مع الكوتش؟ «ناف برو» مفعّل لك ضمن باقتك.</Body>
          {!session && <Button title="تسجيل الدخول" onPress={() => router.push("/login")} />}
          <Button title="شوف الباقات" variant="ghost" onPress={() => router.push("/packages")} />
        </Card>
      )}
    </ScrollView>
  );
}
