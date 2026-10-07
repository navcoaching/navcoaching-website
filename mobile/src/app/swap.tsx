import * as Haptics from "expo-haptics";
import { router, Stack, useLocalSearchParams } from "expo-router";
import { useMemo, useState } from "react";
import { FlatList, Pressable, StyleSheet, Switch, Text, View } from "react-native";
import { Body, Empty } from "@/components/ui";
import { EXERCISES, exercise } from "@/lib/exercises";
import { rankSimilar } from "@/lib/similar";
import { attempt, useTracker } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

// تبديل تمرين بمشابه له: في يوم من البرنامج (target=item) أو في التمرين الجاري (target=workout)
export default function Swap() {
  const { target, id, position, exercise: current, inProgram } = useLocalSearchParams<{
    target: "item" | "workout"; id: string; position?: string; exercise: string; inProgram?: string;
  }>();
  const tracker = useTracker();
  const t = useTheme();
  const ex = exercise(current);
  const list = useMemo(() => rankSimilar(ex, EXERCISES, 12), [current]);
  // من التمرين الجاري: التبديل لهذه الجلسة، ومع الخيار يتبدّل في البرنامج أيضاً (فقط إن كان التمرين من برنامج)
  const [alsoProgram, setAlsoProgram] = useState(true);
  const fromProgram = target === "workout" && inProgram === "1";

  async function pick(newId: string) {
    const ok = await attempt(() => target === "item"
      ? tracker.swapItem(id, newId)
      : tracker.swapWorkoutExercise(id, Number(position), newId, fromProgram && alsoProgram));
    if (!ok) return;
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    router.back();
  }

  return (
    <View style={{ flex: 1 }}>
      <Stack.Screen options={{ title: `بديل ${ex.name}` }} />
      <View style={{ padding: 16, paddingBottom: 8, gap: 8 }}>
        <Body muted>{[ex.muscle, ex.equipment, ex.place].filter(Boolean).join(" · ")}</Body>
        {fromProgram && (
          <View style={s.row}>
            <Text style={{ color: t.text, fontSize: 15, flex: 1, textAlign: "left" }}>بدّله في البرنامج للمرات القادمة</Text>
            <Switch value={alsoProgram} onValueChange={setAlsoProgram} accessibilityLabel="بدّله في البرنامج للمرات القادمة" />
          </View>
        )}
      </View>
      <FlatList data={list} keyExtractor={(e) => e.id} contentContainerStyle={{ paddingHorizontal: 16, paddingBottom: 32 }}
        ListEmptyComponent={<Empty>ما فيه بدائل مشابهة لهذا التمرين في المكتبة.</Empty>}
        renderItem={({ item }) => {
          const e = exercise(item.id);
          return (
            <Pressable onPress={() => pick(item.id)} accessibilityRole="button"
              style={({ pressed }) => [s.item, { borderColor: t.line }, pressed && { opacity: 0.5 }]}>
              <Text style={{ color: t.text, fontSize: 16, fontWeight: "600", textAlign: "left" }}>{item.coach ? "⭐ " : ""}{e.name}</Text>
              <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>
                {[item.coach ? "اختيار الكوتش" : e.muscle, e.equipment, e.place].filter(Boolean).join(" · ")}
              </Text>
            </Pressable>
          );
        }} />
    </View>
  );
}

const s = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", gap: 8, minHeight: 44 },
  item: { paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth, minHeight: 56, justifyContent: "center", gap: 2 },
});
