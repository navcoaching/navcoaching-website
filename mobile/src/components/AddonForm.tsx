import { randomUUID } from "expo-crypto";
import { router } from "expo-router";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Alert, ScrollView, StyleSheet } from "react-native";
import { Body, Button, Card, ErrorText, Field, Title } from "@/components/ui";
import { orderAddon, type Addon } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { useTracker } from "@/lib/tracker/context";

/**
 * نموذج طلب خدمة إضافية: محتوى الخدمة (children) + جوال واتساب + ملاحظة، ثم يُنشأ الطلب وينتقل لطلباتي للتحويل.
 * build() يرجع حقول الخدمة (البرنامج أو الفيديو) أو رسالة خطأ.
 */
export function AddonForm({ addon, children, build }: {
  addon: Addon; children?: ReactNode;
  build: () => Promise<{ fields: Record<string, string | Blob> } | { error: string }>;
}) {
  const tracker = useTracker();
  const { data: session } = authClient.useSession();
  const [phone, setPhone] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const idem = useRef(randomUUID());
  useEffect(() => { tracker.getSetting("phone").then((p) => p && setPhone(p)); }, [tracker]);

  async function submit() {
    if (!session) return router.push("/login");
    setError(null); setBusy(true);
    const b = await build();
    if ("error" in b) { setBusy(false); return setError(b.error); }
    const fd = new FormData();
    fd.append("sku", addon.sku); fd.append("idempotency_key", idem.current);
    fd.append("cc", "+966"); fd.append("phone", phone); fd.append("note", note);
    for (const [k, v] of Object.entries(b.fields)) if (v !== "") fd.append(k, v);
    const r = await orderAddon(fd);
    setBusy(false);
    if (r.error === "login") return router.push("/login");
    if (r.error) return setError(r.error);
    await tracker.setSetting("phone", phone);
    Alert.alert("وصل طلبك", `رقم الطلب ${r.orderNo}. حوّل المبلغ وارفع الإيصال من «طلباتي»، وتبدأ المدربة بعد تأكيد التحويل.`);
    router.replace("/orders");
  }

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Card>
        <Title>{addon.name}</Title>
        {!!addon.about && <Body muted>{addon.about}</Body>}
        <Body>السعر: {addon.price}</Body>
      </Card>
      {children}
      <Field label="جوال واتساب (للتواصل)" value={phone} onChangeText={setPhone} keyboardType="phone-pad" textContentType="telephoneNumber"
        placeholder="05xxxxxxxx" style={{ textAlign: "left", writingDirection: "ltr" }} />
      <Field label="ملاحظة للمدربة (اختياري)" value={note} onChangeText={setNote} maxLength={1000} multiline style={{ minHeight: 80, textAlignVertical: "top" }} />
      {error && <ErrorText>{error}</ErrorText>}
      <Button title={session ? "أرسل الطلب" : "سجّل الدخول للطلب"} busy={busy} onPress={submit} />
      <Body muted>الدفع بالتحويل البنكي بعد إرسال الطلب، من «طلباتي».</Body>
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16, paddingBottom: 48 } });
