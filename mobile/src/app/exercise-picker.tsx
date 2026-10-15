import { router, useLocalSearchParams } from "expo-router";
import { useMemo, useState } from "react";
import { FlatList, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Chip, Empty } from "@/components/ui";
import { MUSCLES, searchExercises, type Exercise } from "@/lib/exercises";
import { attempt, useTracker } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

// اختيار تمرين من المكتبة، ثم إضافته مباشرة ليوم في برنامج أو للتمرين الجاري
export default function ExercisePicker() {
  const { target, id } = useLocalSearchParams<{ target: "day" | "workout"; id: string }>();
  const tracker = useTracker();
  const t = useTheme();
  const [q, setQ] = useState("");
  const [muscle, setMuscle] = useState<string | null>(null);
  const list = useMemo(() => searchExercises(q, muscle), [q, muscle]);

  async function pick(ex: Exercise) {
    const ok = await attempt(() => (target === "day" ? tracker.addItem(id, ex.id) : tracker.addExerciseToWorkout(id, ex.id)));
    if (ok) router.back();
  }

  return (
    <View style={{ flex: 1 }}>
      <View style={{ padding: 16, paddingBottom: 8, gap: 10 }}>
        <TextInput value={q} onChangeText={setQ} placeholder="ابحث باسم التمرين أو العضلة أو الأداة" placeholderTextColor={t.muted}
          autoCorrect={false} clearButtonMode="while-editing" accessibilityLabel="بحث"
          style={[s.search, { color: t.text, borderColor: t.line, backgroundColor: t.surface }]} />
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
          <Chip label="الكل" active={!muscle} onPress={() => setMuscle(null)} />
          {MUSCLES.map((m) => <Chip key={m} label={m} active={muscle === m} onPress={() => setMuscle(m)} />)}
        </ScrollView>
      </View>
      <FlatList
        data={list}
        keyExtractor={(e) => e.id}
        keyboardShouldPersistTaps="handled"
        contentContainerStyle={{ paddingHorizontal: 16, paddingBottom: 32 }}
        ListEmptyComponent={<Empty>لا توجد نتائج.</Empty>}
        renderItem={({ item }) => (
          <Pressable onPress={() => pick(item)} accessibilityRole="button"
            style={({ pressed }) => [s.row, { borderColor: t.line }, pressed && { opacity: 0.5 }]}>
            <Text style={[s.name, { color: t.text }]}>{item.name}</Text>
            <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>
              {[item.muscle, item.equipment, item.place].filter(Boolean).join(" · ")}
            </Text>
          </Pressable>
        )}
      />
    </View>
  );
}

const s = StyleSheet.create({
  search: { minHeight: 48, borderWidth: 1, borderRadius: 12, paddingHorizontal: 14, fontSize: 16, textAlign: "right" },
  row: { paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth, minHeight: 56, justifyContent: "center", gap: 2 },
  name: { fontSize: 16, fontWeight: "600", textAlign: "left" },
});
