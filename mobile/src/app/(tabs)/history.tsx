import { router } from "expo-router";
import { FlatList, Pressable, StyleSheet, Text, View } from "react-native";
import { Empty } from "@/components/ui";
import { StatsRow } from "@/components/WorkoutStats";
import { useScreenData } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

const dateFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { weekday: "long", day: "numeric", month: "long" });

export default function History() {
  const t = useTheme();
  const { data } = useScreenData((tr) => tr.history(100));
  if (!data) return null;
  return (
    <FlatList
      data={data}
      keyExtractor={(w) => w.id}
      contentContainerStyle={{ padding: 16, gap: 12 }}
      contentInsetAdjustmentBehavior="automatic"
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
