import { router } from "expo-router";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { CoachPrograms } from "@/components/CoachPrograms";
import { Body, Button, Card, Empty, Title } from "@/components/ui";
import { attempt, useScreenData, useTracker } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

// الشاشة الرئيسية: برامجي وأيامها، وبدء التمرين. تعمل بدون حساب وبدون إنترنت.
export default function Home() {
  const t = useTheme();
  const tracker = useTracker();
  const { data } = useScreenData(async (tr) => ({ programs: await tr.listPrograms(), active: await tr.activeWorkoutId(), imported: await tr.importedSources() }));

  async function start(from: { dayId: string } | { title: string }) {
    let id = "";
    if (await attempt(async () => { id = await tracker.startWorkout(from); })) router.push(`/workout/${id}`);
  }

  if (!data) return null;
  return (
    <ScrollView contentContainerStyle={s.page} contentInsetAdjustmentBehavior="automatic">
      {data.active && (
        <Pressable onPress={() => router.push(`/workout/${data.active}`)} accessibilityRole="button"
          style={[s.banner, { backgroundColor: t.navy }]}>
          <Text style={[s.bannerText, { color: t.onAccent }]}>عندك تمرين جارٍ — اضغط للمتابعة</Text>
        </Pressable>
      )}

      {data.programs.length === 0 && <CoachPrograms imported={data.imported} />}

      {data.programs.length === 0 ? (
        <Card>
          <Title>أو ابنِ جدولك بنفسك</Title>
          <Body muted>ابنِ برنامجك: الأيام، التمارين، الجولات والتكرارات والوزن المستهدف. وسجّل أوزانك في كل تمرين وتابع تقدّمك.</Body>
          <Body muted>مجاني، ويُحفظ على جوالك بدون حساب.</Body>
          <Button title="برنامج جديد" onPress={() => router.push("/program/new")} />
        </Card>
      ) : (
        data.programs.map((p) => (
          <Card key={p.id}>
            <View style={s.head}>
              <Title>{p.name}</Title>
              <Pressable onPress={() => router.push(`/program/${p.id}`)} accessibilityRole="button" hitSlop={10}>
                <Text style={{ color: t.navy, fontSize: 16, fontWeight: "600" }}>تعديل</Text>
              </Pressable>
            </View>
            {p.days.map((d) => (
              <View key={d.id} style={[s.day, { borderColor: t.line }]}>
                <View style={{ flex: 1 }}>
                  <Text style={[s.dayTitle, { color: t.text }]}>{d.title}</Text>
                  <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>{d.items === 0 ? "بدون تمارين بعد" : `${d.items} تمارين`}</Text>
                </View>
                <View style={{ width: 96 }}>
                  <Button title="ابدأ" disabled={!!data.active || d.items === 0} onPress={() => start({ dayId: d.id })} />
                </View>
              </View>
            ))}
          </Card>
        ))
      )}

      {data.programs.length > 0 && <CoachPrograms imported={data.imported} />}
      {data.programs.length > 0 && <Button title="برنامج جديد" variant="ghost" onPress={() => router.push("/program/new")} />}
      <Button title="تمرين حر بدون برنامج" variant="ghost" disabled={!!data.active} onPress={() => start({ title: "تمرين حر" })} />
      {data.programs.length === 0 && <Empty>التمارين من مكتبة الكوتش ساره، ولكل تمرين شرح وفيديو.</Empty>}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16 },
  banner: { borderRadius: 14, padding: 16, minHeight: 50, justifyContent: "center" },
  bannerText: { fontSize: 16, fontWeight: "700", textAlign: "center" },
  head: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
  day: { flexDirection: "row", alignItems: "center", gap: 12, borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 10 },
  dayTitle: { fontSize: 17, fontWeight: "600", textAlign: "left" },
});
