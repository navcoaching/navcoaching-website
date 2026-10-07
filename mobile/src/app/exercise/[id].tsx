import { router, Stack, useLocalSearchParams } from "expo-router";
import { Linking, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { LineChart } from "@/components/Charts";
import { Body, Button, Card, Title } from "@/components/ui";
import { exercise } from "@/lib/exercises";
import { useScreenData } from "@/lib/tracker/context";
import { formatKg } from "@/lib/tracker/logic";
import { useTheme } from "@/lib/theme";

const dateFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { day: "numeric", month: "short" });
const axisFmt = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "numeric" });

export default function ExerciseDetail() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const t = useTheme();
  const ex = exercise(id);
  const { data: hist } = useScreenData((tr) => tr.exerciseHistory(id), [id]);
  const best = hist?.reduce((m, h) => Math.max(m, h.best_e1rm), 0) ?? 0;
  const recent = hist?.slice(-20) ?? [];

  return (
    <ScrollView contentContainerStyle={s.page}>
      <Stack.Screen options={{ title: ex.name }} />
      <Card>
        <Title>{ex.name}</Title>
        <Body muted>{[ex.muscle, ...ex.secondary].filter(Boolean).join(" · ")}</Body>
        <Body muted>{[ex.equipment, ex.place, ex.level].filter(Boolean).join(" · ")}</Body>
        {!!ex.instructions && <Body>{ex.instructions}</Body>}
        {!!ex.video && <Button title="شاهد طريقة الأداء (فيديو)" variant="ghost" onPress={() => Linking.openURL(ex.video!)} />}
      </Card>

      <Card>
        <Title>سجلك</Title>
        {!hist || hist.length === 0 ? (
          <Body muted>ما سجلت هذا التمرين بعد.</Body>
        ) : (
          <>
            <Body>أفضل 1RM تقديري: {formatKg(best)} كجم</Body>
            {recent.length >= 2 && recent[recent.length - 1].max_weight > 0 && (
              <>
                <LineChart label="1RM تقديري" unit="كجم" points={recent.map((h) => ({ x: axisFmt.format(h.finished_at), y: h.best_e1rm }))} />
                <LineChart label="أثقل وزن" unit="كجم" height={150} points={recent.map((h) => ({ x: axisFmt.format(h.finished_at), y: h.max_weight }))} />
              </>
            )}
            {recent.length === 1 && <Body muted>الرسم البياني يظهر من ثاني تمرين.</Body>}
            {[...hist].reverse().slice(0, 10).map((h) => (
              <View key={h.workout_id} style={[s.row, { borderColor: t.line }]}>
                <Text style={{ color: t.muted, fontSize: 15 }}>{dateFmt.format(h.finished_at)}</Text>
                <Text style={{ color: t.text, fontSize: 15, writingDirection: "ltr" }}>{formatKg(h.max_weight)} kg × {h.best_reps}</Text>
              </View>
            ))}
          </>
        )}
      </Card>

      {ex.alts.length > 0 && (
        <Card>
          <Title>بدائل</Title>
          {ex.alts.map((a) => (
            <Pressable key={a} onPress={() => router.push(`/exercise/${a}`)} accessibilityRole="link" style={{ minHeight: 40, justifyContent: "center" }}>
              <Text style={{ color: t.navy, fontSize: 16, textAlign: "left" }}>{exercise(a).name}</Text>
            </Pressable>
          ))}
        </Card>
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", justifyContent: "space-between", borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 8 },
});
