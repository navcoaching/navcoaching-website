import { router, Stack, useLocalSearchParams } from "expo-router";
import { Alert, ScrollView, StyleSheet, Text, View } from "react-native";
import { Button, Card, Empty, Title } from "@/components/ui";
import { ShareCard } from "@/components/ShareCard";
import { RecordsList, StatsRow } from "@/components/WorkoutStats";
import { exercise } from "@/lib/exercises";
import { attempt, useScreenData, useTracker } from "@/lib/tracker/context";
import { formatKg } from "@/lib/tracker/logic";
import { useTheme } from "@/lib/theme";

export default function WorkoutDetail() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const tracker = useTracker();
  const t = useTheme();
  const { data } = useScreenData(async (tr) => ({ w: await tr.getWorkout(id), sum: await tr.summary(id) }), [id]);
  if (!data) return null;
  if (!data.w || !data.sum) return <Empty>التمرين غير موجود.</Empty>;
  const { w, sum } = data;

  return (
    <ScrollView contentContainerStyle={s.page}>
      <Stack.Screen options={{ title: w.title }} />
      <Card>
        <StatsRow s={sum} />
        <RecordsList s={sum} />
      </Card>
      {w.exercises.map((ex) => (
        <Card key={ex.position}>
          <Title>{exercise(ex.exercise_id).name}</Title>
          {ex.sets.map((set, i) => (
            <View key={set.id} style={[s.row, { borderColor: t.line }]}>
              <Text style={{ color: t.muted, fontSize: 15 }}>{set.kind === "warmup" ? "إحماء" : set.kind === "drop" ? "دروب" : `جولة ${i + 1}`}</Text>
              <Text style={{ color: t.text, fontSize: 15, writingDirection: "ltr" }}>{formatKg(set.weight)} kg × {set.reps}</Text>
            </View>
          ))}
        </Card>
      ))}
      <ShareCard s={sum} />
      <Button title="حذف من السجل" variant="ghost" onPress={() => Alert.alert("حذف التمرين من السجل؟", "لا يمكن التراجع.", [
        { text: "إلغاء", style: "cancel" },
        { text: "حذف", style: "destructive", onPress: () => attempt(() => tracker.deleteWorkout(id)).then((ok) => ok && router.back()) },
      ])} />
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", justifyContent: "space-between", borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 8 },
});
