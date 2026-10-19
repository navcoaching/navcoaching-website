import * as Haptics from "expo-haptics";
import { Redirect } from "expo-router";
import { useEffect, useState } from "react";
import { ScrollView, StyleSheet, Switch, Text, View } from "react-native";
import { Body, Button, Card, ErrorText, Field, Title } from "@/components/ui";
import { apiAction } from "@/lib/api";
import { useApi } from "@/lib/use-api";
import { useTheme } from "@/lib/theme";

type Profile = { name: string; email: string; phone: string | null; prefs: { email: boolean; whatsapp: boolean } };

// بياناتي: الاسم وتفضيلات التواصل (مثل «حسابي» في الموقع)
export default function ProfileScreen() {
  const t = useTheme();
  const { data, error, reload } = useApi<Profile>("/profile");
  const [name, setName] = useState("");
  const [email, setEmail] = useState(true);
  const [whatsapp, setWhatsapp] = useState(true);
  const [msg, setMsg] = useState<{ ok?: string; error?: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  useEffect(() => { if (data) { setName(data.name); setEmail(data.prefs.email); setWhatsapp(data.prefs.whatsapp); } }, [data]);
  if (error === "login") return <Redirect href="/login" />;
  if (error && !data) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!data) return null;

  async function run(name_: string, fields: Record<string, string>) {
    setBusy(name_); setMsg(null);
    const fd = new FormData();
    for (const [k, v] of Object.entries(fields)) fd.append(k, v);
    const r = await apiAction(name_, fd);
    setBusy(null);
    if (r.error) return setMsg({ error: r.error });
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    setMsg({ ok: r.message }); reload();
  }

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      {msg?.error && <ErrorText>{msg.error}</ErrorText>}
      {msg?.ok && <Text style={{ color: t.navy, textAlign: "center" }}>{msg.ok}</Text>}
      <Card>
        <Title>بياناتي</Title>
        <Body muted>{data.email}{data.phone ? ` · ${data.phone}` : ""}</Body>
        <Field label="الاسم" value={name} onChangeText={setName} maxLength={80} />
        <Button title="حفظ الاسم" busy={busy === "update-profile"} disabled={name.trim().length < 2 || name.trim() === data.name} onPress={() => run("update-profile", { name: name.trim() })} />
      </Card>
      <Card>
        <Title>التواصل والتنبيهات</Title>
        <Body muted>كيف توصلك تنبيهات طلبك وردود المدربة.</Body>
        {([["البريد الإلكتروني", email, setEmail], ["واتساب", whatsapp, setWhatsapp]] as const).map(([label, v, set]) => (
          <View key={label} style={s.row}>
            <Text style={{ color: t.text, fontSize: 16, flex: 1, textAlign: "left" }}>{label}</Text>
            <Switch value={v} onValueChange={set} accessibilityLabel={label} />
          </View>
        ))}
        <Button title="حفظ التفضيلات" variant="ghost" busy={busy === "save-prefs"}
          onPress={() => run("save-prefs", { ...(email ? { email_enabled: "on" } : {}), ...(whatsapp ? { whatsapp_enabled: "on" } : {}) })} />
      </Card>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", alignItems: "center", minHeight: 48 },
});
