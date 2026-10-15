import { router } from "expo-router";
import { useEffect, useState } from "react";
import { Alert, Linking, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Chip, IconButton, Title } from "@/components/ui";
import { DEFAULT_PREFS, loadPrefs, savePrefs, timeLabel, WEEKDAYS, type ReminderPrefs } from "@/lib/reminders";
import { useTracker } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

export default function Reminders() {
  const tracker = useTracker();
  const t = useTheme();
  const [p, setP] = useState<ReminderPrefs | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { loadPrefs(tracker).then(setP); }, [tracker]);
  if (!p) return null;

  const toggle = (d: number) => setP({ ...p, days: p.days.includes(d) ? p.days.filter((x) => x !== d) : [...p.days, d].sort() });
  const shiftHour = (delta: number) => setP({ ...p, hour: (p.hour + delta + 24) % 24 });

  async function save() {
    setBusy(true);
    const ok = await savePrefs(tracker, p!).catch(() => false);
    setBusy(false);
    if (ok) router.back();
    else Alert.alert("التنبيهات مقفلة", "فعّل تنبيهات Nav Coaching من إعدادات الجوال حتى يوصلك التذكير.", [
      { text: "لاحقاً", style: "cancel" },
      { text: "فتح الإعدادات", onPress: () => Linking.openSettings() },
    ]);
  }

  return (
    <ScrollView contentContainerStyle={s.page}>
      <Card>
        <Title>أيام التمرين</Title>
        <Body muted>يوصلك تذكير في هذه الأيام. يعمل بدون إنترنت.</Body>
        <View style={s.wrap}>
          {WEEKDAYS.map((name, i) => <Chip key={name} label={name} active={p.days.includes(i + 1)} onPress={() => toggle(i + 1)} />)}
        </View>
      </Card>
      <Card>
        <Title>الوقت</Title>
        <View style={s.time}>
          <IconButton name="remove-circle-outline" label="ساعة أبكر" onPress={() => shiftHour(-1)} color={t.navy} />
          <Text style={[s.timeText, { color: t.heading }]} accessibilityLiveRegion="polite">{timeLabel(p.hour, p.minute)}</Text>
          <IconButton name="add-circle-outline" label="ساعة أتأخر" onPress={() => shiftHour(1)} color={t.navy} />
        </View>
        <View style={s.wrap}>
          {[0, 15, 30, 45].map((m) => <Chip key={m} label={`:${String(m).padStart(2, "0")}`} active={p.minute === m} onPress={() => setP({ ...p, minute: m })} />)}
        </View>
      </Card>
      <Button title={p.days.length ? "حفظ التذكير" : "إيقاف التذكير"} busy={busy} onPress={save} />
      {p.days.length > 0 && <Button title="بدون تذكير" variant="ghost" onPress={() => setP({ ...DEFAULT_PREFS })} />}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16 },
  wrap: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  time: { flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 16 },
  timeText: { fontSize: 28, fontWeight: "800", minWidth: 120, textAlign: "center", fontVariant: ["tabular-nums"] },
});
