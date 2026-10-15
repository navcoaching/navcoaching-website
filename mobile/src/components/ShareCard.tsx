import * as Sharing from "expo-sharing";
import { useRef, useState } from "react";
import { Alert, StyleSheet, Text, View } from "react-native";
import { captureRef } from "react-native-view-shot";
import { Button } from "@/components/ui";
import { exercise } from "@/lib/exercises";
import { formatDuration, formatKg } from "@/lib/tracker/logic";
import type { WorkoutSummary } from "@/lib/tracker/repo";

const dateFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { weekday: "long", day: "numeric", month: "long" });

/** بطاقة إنجاز التمرين (صورة مربعة) لمشاركتها في سناب وانستقرام. ألوان ثابتة بهوية Nav بغض النظر عن وضع الجوال. */
export function ShareCard({ s }: { s: WorkoutSummary }) {
  const ref = useRef<View>(null);
  const [busy, setBusy] = useState(false);

  async function share() {
    setBusy(true);
    try {
      const uri = await captureRef(ref, { format: "png", quality: 1, result: "tmpfile" });
      if (!(await Sharing.isAvailableAsync())) { Alert.alert("تنبيه", "المشاركة غير متاحة على هذا الجهاز."); return; }
      await Sharing.shareAsync(uri, { mimeType: "image/png", dialogTitle: "شارك إنجازك", UTI: "public.png" });
    } catch (e) {
      console.error(e);
      Alert.alert("خطأ", "تعذّر تجهيز الصورة.");
    } finally {
      setBusy(false);
    }
  }

  const stats: [string, string][] = [
    ["المدة", formatDuration(s.duration_sec)],
    ["الحجم (كجم)", s.volume.toLocaleString("en-US")],
    ["الجولات", String(s.sets)],
  ];
  return (
    <View style={{ gap: 12 }}>
      <View ref={ref} collapsable={false} style={c.card}>
        <Text style={c.brand}>Nav Coaching</Text>
        <Text style={c.title} numberOfLines={2}>{s.title}</Text>
        <Text style={c.date}>{dateFmt.format(s.finished_at)}</Text>
        <View style={c.stats}>
          {stats.map(([k, v]) => (
            <View key={k} style={{ flex: 1, alignItems: "center" }}>
              <Text style={c.value}>{v}</Text>
              <Text style={c.label}>{k}</Text>
            </View>
          ))}
        </View>
        {s.records.slice(0, 3).map((r) => (
          <Text key={`${r.exerciseId}-${r.type}`} style={c.record} numberOfLines={1}>
            🏆 {exercise(r.exerciseId).name} · {formatKg(r.value)} كجم
          </Text>
        ))}
        <Text style={c.footer}>سجّل تمرينك مجاناً مع Nav Coaching</Text>
      </View>
      <Button title="شارك إنجازك" variant="ghost" busy={busy} onPress={share} />
    </View>
  );
}

const c = StyleSheet.create({
  card: { aspectRatio: 1, backgroundColor: "#07142a", borderRadius: 20, padding: 22, justifyContent: "space-between" },
  brand: { color: "#4cc5ed", fontSize: 16, fontWeight: "800", textAlign: "left", letterSpacing: 1 },
  title: { color: "#ffffff", fontSize: 24, fontWeight: "800", textAlign: "left" },
  date: { color: "#a9bad0", fontSize: 14, textAlign: "left" },
  stats: { flexDirection: "row", backgroundColor: "#122232", borderRadius: 14, paddingVertical: 12 },
  value: { color: "#ffffff", fontSize: 22, fontWeight: "800", fontVariant: ["tabular-nums"] },
  label: { color: "#a9bad0", fontSize: 12 },
  record: { color: "#eaf2fb", fontSize: 15, textAlign: "left" },
  footer: { color: "#a9bad0", fontSize: 12, textAlign: "center" },
});
