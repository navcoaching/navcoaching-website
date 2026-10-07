import { router, Stack, useLocalSearchParams } from "expo-router";
import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Empty, Title } from "@/components/ui";
import { cachedCoachProgram } from "@/lib/coach-programs";
import { exercise } from "@/lib/exercises";
import { attempt, useScreenData, useTracker } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

// معاينة برنامج من برامج المدربة المجانية، ثم نسخه للجهاز
export default function CoachProgramScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const tracker = useTracker();
  const t = useTheme();
  const p = cachedCoachProgram(id);
  const { data: imported } = useScreenData((tr) => tr.importedSources());
  const [busy, setBusy] = useState(false);
  if (!p) return <Empty>البرنامج غير متاح. ارجع للرئيسية وحاول مرة ثانية.</Empty>;

  async function add() {
    setBusy(true);
    let newId = "";
    const ok = await attempt(async () => { newId = await tracker.importProgram({ sourceId: p!.id, name: p!.name, days: p!.days }); });
    setBusy(false);
    if (ok) router.replace(`/program/${newId}`);
  }

  return (
    <ScrollView contentContainerStyle={s.page}>
      <Stack.Screen options={{ title: p.name }} />
      <Card>
        <Title>{p.name}</Title>
        {!!p.summary && <Body muted>{p.summary}</Body>}
        {!!p.instructions && <Body>{p.instructions}</Body>}
        <Body muted>يُضاف لبرامجك كنسخة تقدر تعدّلها: الأوزان، التمارين، والأيام.</Body>
        {imported?.has(p.id) && <Body muted>سبق وأضفت هذا البرنامج. تقدر تضيفه مرة ثانية كنسخة جديدة.</Body>}
        <Button title="أضف لبرامجي" busy={busy} onPress={add} />
      </Card>
      {p.days.map((d, di) => (
        <Card key={di}>
          <Title>{d.title}</Title>
          {d.items.map((it, ii) => (
            <Pressable key={ii} onPress={() => router.push(`/exercise/${it.exercise_id}`)} accessibilityRole="link"
              style={[s.row, { borderColor: t.line }]}>
              <Text style={[s.ex, { color: t.text }]}>{exercise(it.exercise_id).muscle ? exercise(it.exercise_id).name : it.name}</Text>
              <View style={{ alignItems: "flex-end" }}>
                <Text style={{ color: t.muted, fontSize: 14, writingDirection: "ltr" }}>{it.sets} × {it.reps}</Text>
                {it.rir != null && <Text style={{ color: t.muted, fontSize: 12 }}>RIR {it.rir}</Text>}
              </View>
            </Pressable>
          ))}
        </Card>
      ))}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 8, minHeight: 44, gap: 8 },
  ex: { fontSize: 16, flex: 1, textAlign: "left" },
});
