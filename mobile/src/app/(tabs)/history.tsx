import { router } from "expo-router";
import { FlatList, Pressable, StyleSheet, Text, View } from "react-native";
import { Empty } from "@/components/ui";
import { WeekBars } from "@/components/Charts";
import { StatsRow } from "@/components/WorkoutStats";
import { useScreenData } from "@/lib/tracker/context";
import { weeklyCounts } from "@/lib/tracker/logic";
import { useTheme } from "@/lib/theme";

const dateFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { weekday: "long", day: "numeric", month: "long" });
const weekFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "numeric" });

export default function History() {
  const t = useTheme();
  const { data } = useScreenData((tr) => tr.history(100));
  if (!data) return null;
  const weeks = weeklyCounts(data.map((w) => w.finished_at), 8, Date.now()).map((w) => ({ label: weekFmt.format(w.start), count: w.count }));
  return (
    <FlatList
      data={data}
      keyExtractor={(w) => w.id}
      contentContainerStyle={{ padding: 16, gap: 12 }}
      contentInsetAdjustmentBehavior="automatic"
      ListHeaderComponent={data.length > 0 ? (
        <View style={[s.card, { backgroundColor: t.surface, borderColor: t.line }]}>
          <Text style={[s.title, { color: t.heading }]}>تمارينك آخر 8 أسابيع</Text>
          <WeekBars weeks={weeks} />
        </View>
      ) : null}
      ListEmptyComponent={<Empty>تمارينك المكتملة تظهر هنا.</Empty>}
      renderItem={({ item }) => (
        <Pressable onPress={() => router.push(`/history/${item.id}`)} accessibilityRole="button"
          style={({ pressed }) => [s.card, { backgroundColor: t.surface, borderColor: t.line }, pressed && { opacity: 0.6 }]}>
          <View style={s.head}>
            <Text style={[s.title, { color: t.heading }]} numberOfLines={1}>{item.title}</Text>
            {item.records.length > 0 && <Text style={{ fontSize: 14, color: t.navy }}>🏆 {item.records.length}</Text>}
          </View>
          <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>{dateFmt.format(item.finished_at)}</Text>
          <StatsRow s={item} />
        </Pressable>
      )}
    />
  );
}

const s = StyleSheet.create({
  card: { borderWidth: 1, borderRadius: 16, padding: 14, gap: 6 },
  head: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 8 },
  title: { fontSize: 17, fontWeight: "700", flex: 1, textAlign: "left" },
});
