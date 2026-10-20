import { StyleSheet, Text, View } from "react-native";
import { exercise } from "@/lib/exercises";
import { formatDuration, formatKg } from "@/lib/tracker/logic";
import type { WorkoutSummary } from "@/lib/tracker/repo";
import { useTheme } from "@/lib/theme";

export function StatsRow({ s: w }: { s: WorkoutSummary }) {
  const t = useTheme();
  const items: [string, string][] = [
    ["المدة", formatDuration(w.duration_sec)],
    ["الحجم (كجم)", w.volume.toLocaleString("en-US")],
    ["الجولات", String(w.sets)],
  ];
  return (
    <View style={st.row}>
      {items.map(([k, v]) => (
        <View key={k} style={{ flex: 1, alignItems: "center" }}>
          <Text style={{ color: t.heading, fontSize: 20, fontWeight: "800", fontVariant: ["tabular-nums"] }}>{v}</Text>
          <Text style={{ color: t.muted, fontSize: 13 }}>{k}</Text>
        </View>
      ))}
    </View>
  );
}

export function RecordsList({ s: w }: { s: WorkoutSummary }) {
  const t = useTheme();
  if (w.records.length === 0) return null;
  return (
    <View style={{ gap: 6 }}>
      {w.records.map((r) => (
        <Text key={`${r.exerciseId}-${r.type}`} style={{ color: t.text, fontSize: 15, textAlign: "left" }}>
          🏆 {exercise(r.exerciseId).name}: {r.type === "weight" ? "أثقل وزن" : "أفضل 1RM تقديري"} {formatKg(r.value)} كجم
          {r.previous != null ? ` (كان ${formatKg(r.previous)})` : ""}
        </Text>
      ))}
    </View>
  );
}

const st = StyleSheet.create({ row: { flexDirection: "row", paddingVertical: 4 } });
