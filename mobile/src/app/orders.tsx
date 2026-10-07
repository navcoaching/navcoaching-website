import * as Clipboard from "expo-clipboard";
import * as ImagePicker from "expo-image-picker";
import { Redirect, useFocusEffect } from "expo-router";
import { useCallback, useState } from "react";
import { Alert, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Empty, ErrorText, Title } from "@/components/ui";
import { api, apiAction, ApiError, type Order, type Orders } from "@/lib/api";
import { useTheme } from "@/lib/theme";

// طلباتي: الحالة، وبيانات التحويل البنكي، ورفع صورة الإيصال (نفس مسار الموقع)
export default function OrdersScreen() {
  const [data, setData] = useState<Orders | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => {
    api<Orders>("/orders").then((d) => { setData(d); setError(null); }).catch((e) =>
      setError(e instanceof ApiError && e.status === 401 ? "login" : "تعذّر تحميل طلباتك. تأكد من الاتصال."));
  }, []);
  useFocusEffect(useCallback(() => { load(); }, [load]));

  if (error === "login") return <Redirect href="/login" />;
  return (
    <ScrollView contentContainerStyle={s.page}>
      {error && <ErrorText>{error}</ErrorText>}
      {data && data.orders.length === 0 && <Empty>ما عندك طلبات.</Empty>}
      {data?.orders.map((o) => <OrderCard key={o.order_no} o={o} bank={data.bank} onChange={load} />)}
    </ScrollView>
  );
}

function OrderCard({ o, bank, onChange }: { o: Order; bank: Orders["bank"]; onChange: () => void }) {
  const t = useTheme();
  const [busy, setBusy] = useState(false);
  const waiting = o.status === "awaiting_payment";

  async function upload(source: "library" | "camera") {
    const opts: ImagePicker.ImagePickerOptions = { mediaTypes: ["images"], quality: 0.7 };
    if (source === "camera") {
      const perm = await ImagePicker.requestCameraPermissionsAsync();
      if (!perm.granted) return Alert.alert("الكاميرا مقفلة", "اسمح للتطبيق بالكاميرا من إعدادات الجوال، أو اختر الصورة من الألبوم.");
    }
    const r = source === "camera" ? await ImagePicker.launchCameraAsync(opts) : await ImagePicker.launchImageLibraryAsync(opts);
    if (r.canceled) return;
    const a = r.assets[0];
    // quality أقل من 1 يحوّل صور الآيفون (HEIC) إلى JPEG، وهي من الصيغ المقبولة في الموقع
    const fd = new FormData();
    fd.append("order_no", o.order_no);
    fd.append("proof", { uri: a.uri, name: a.fileName ?? "receipt.jpg", type: a.mimeType ?? "image/jpeg" } as unknown as Blob);
    setBusy(true);
    const res = await apiAction("upload-proof", fd);
    setBusy(false);
    Alert.alert(res.error ? "تنبيه" : "تم", res.error ?? res.message ?? "وصلنا الإيصال.");
    if (!res.error) onChange();
  }

  function cancel() {
    Alert.alert("إلغاء الطلب؟", "تقدر تطلب من جديد في أي وقت.", [
      { text: "رجوع", style: "cancel" },
      { text: "إلغاء الطلب", style: "destructive", onPress: async () => {
        const fd = new FormData();
        fd.append("order_no", o.order_no);
        const res = await apiAction("cancel-order", fd);
        if (res.error) Alert.alert("تنبيه", res.error); else onChange();
      } },
    ]);
  }

  return (
    <Card>
      <Title>{o.product_name}</Title>
      <Body muted>طلب {o.order_no}{o.amount ? ` · ${o.amount}` : ""}</Body>
      <Text style={{ color: waiting ? t.err : t.navy, fontSize: 16, fontWeight: "700", textAlign: "left" }}>{o.status_label}</Text>
      {waiting && bank && (
        <View style={[s.bank, { backgroundColor: t.paper, borderColor: t.line }]}>
          <Body>حوّل المبلغ على الحساب التالي ثم ارفع صورة الإيصال. اكتب رقم الطلب في ملاحظة التحويل إن أمكن.</Body>
          <Body muted>اسم الحساب: {bank.accountName}</Body>
          <Body muted>البنك: {bank.bankName}</Body>
          <Text selectable style={{ color: t.text, fontSize: 16, writingDirection: "ltr", textAlign: "left" }}>{bank.iban}</Text>
          <View style={{ flexDirection: "row", gap: 8 }}>
            <View style={{ flex: 1 }}><Button title="نسخ الآيبان" variant="ghost" onPress={() => Clipboard.setStringAsync(bank.iban).then(() => Alert.alert("تم النسخ"))} /></View>
            <View style={{ flex: 1 }}><Button title="نسخ رقم الطلب" variant="ghost" onPress={() => Clipboard.setStringAsync(o.order_no).then(() => Alert.alert("تم النسخ"))} /></View>
          </View>
        </View>
      )}
      {waiting && (
        <>
          <Button title="ارفع صورة الإيصال" busy={busy} onPress={() => upload("library")} />
          <Button title="صوّر الإيصال بالكاميرا" variant="ghost" disabled={busy} onPress={() => upload("camera")} />
          <Button title="إلغاء الطلب" variant="ghost" onPress={cancel} />
        </>
      )}
      {o.status === "payment_review" && <Body muted>نراجع التحويل ونحدّث حالة طلبك بعد التأكد من وصول المبلغ.</Body>}
    </Card>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  bank: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 6 },
});
