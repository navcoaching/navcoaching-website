import { Stack } from "expo-router";
import { useState } from "react";
import { View } from "react-native";
import { AddonForm } from "@/components/AddonForm";
import { Body, Card, Chip, Empty, Title } from "@/components/ui";
import { useAddons } from "@/lib/addons";
import { exercise } from "@/lib/exercises";
import { useScreenData, useTracker } from "@/lib/tracker/context";

const DAY = 86_400_000;

// «راجعي جدولي»: يختار المستخدم برنامجه، ويُرسل البرنامج وسجل آخر 4 أسابيع مع الطلب
export default function ReviewRequest() {
  const tracker = useTracker();
  const { addons } = useAddons();
  const addon = addons?.find((a) => a.kind === "program_review");
  const { data } = useScreenData(async (tr) => ({ programs: await tr.listPrograms(), sessions: (await tr.history(200)).filter((h) => h.finished_at >= Date.now() - 28 * DAY).length }));
  const [programId, setProgramId] = useState<string | null>(null);
  if (!addon || !data) return addons && !addon ? <Empty>الخدمة غير متاحة حالياً.</Empty> : null;
  if (data.programs.length === 0) return <Empty>ابنِ برنامجك أولاً وسجّل تمارينك، ثم اطلب المراجعة.</Empty>;
  const chosen = programId ?? data.programs[0].id;

  return (
    <View style={{ flex: 1 }}>
      <Stack.Screen options={{ title: addon.name }} />
      <AddonForm addon={addon} build={async () => {
        const snap = await tracker.reviewSnapshot(chosen, Date.now() - 28 * DAY);
        if (!snap) return { error: "اختر البرنامج." };
        // أسماء التمارين بدل المعرّفات، والتواريخ نصاً (حتى تقرأها المدربة مباشرة)
        const payload = {
          program: { name: snap.program.name, days: snap.program.days.map((d) => ({ title: d.title, items: d.items.map((i) => ({ name: exercise(i.exercise_id).name, sets: i.sets, reps: i.reps, target_weight: i.target_weight })) })) },
          sessions: snap.sessions.map((x) => ({
            date: new Date(x.finished_at).toISOString().slice(0, 10), title: x.title,
            exercises: x.exercises.map((e) => ({ name: exercise(e.exercise_id).name, sets: e.sets })),
          })),
        };
        return { fields: { payload: JSON.stringify(payload) } };
      }}>
        <Card>
          <Title>البرنامج اللي تراجعه المدربة</Title>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
            {data.programs.map((p) => <Chip key={p.id} label={p.name} active={p.id === chosen} onPress={() => setProgramId(p.id)} />)}
          </View>
          <Body muted>يُرسل مع البرنامج سجل تمارينك لآخر 4 أسابيع ({data.sessions} تمرين). المدربة ترجع لك بتعديلات عملية.</Body>
        </Card>
      </AddonForm>
    </View>
  );
}
