import { Redirect, router, Stack } from "expo-router";
import { useEffect, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Chip, Empty, ErrorText, Title } from "@/components/ui";
import { openSite } from "@/lib/links";
import { planText, useCoaching } from "@/lib/coaching";
import { formatKg } from "@/lib/tracker/logic";
import { useTheme } from "@/lib/theme";

// برنامج المدربة للمتدرب: الأسبوع، ملاحظات المدربة، أيام البرنامج، والتسجيل
export default function CoachingScreen() {
  const t = useTheme();
  const { data, error } = useCoaching();
  const [week, setWeek] = useState<number | null>(null);
  const [dayId, setDayId] = useState<string | null>(null);
  const block = data?.block;
  useEffect(() => { if (block && week === null) setWeek(Math.max(1, block.current_week || 1)); }, [block?.id]);

  if (error === "login") return <Redirect href="/login" />;
  if (error && !data) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!data) return null;
  if (!block) return <Empty>برنامجك يظهر هنا بعد تأكيد الاشتراك وإسناد المدربة للبرنامج، ويصلك إشعار.</Empty>;

  const w = week ?? 1;
  const days = data.days ?? [];
  const day = days.find((d) => d.id === dayId) ?? days.find((d) => d.items.some((i) => !data.logs?.some((l) => l.item === i.id && l.week === w))) ?? days[0];
  const notes = (data.notes ?? []).filter((n) => n.week == null || n.week === w);
  const logOf = (item: string) => data.logs?.find((l) => l.item === item && l.week === w);

  return (
    <ScrollView contentContainerStyle={s.page}>
      <Stack.Screen options={{ title: block.name }} />
      <Card>
        <Title>{block.name}</Title>
        <Body muted>
          {block.current_week === 0 ? `يبدأ ${block.start_date}` : `الأسبوع ${w} من ${block.weeks}`}
          {block.read_only ? " · منتهي (للقراءة فقط)" : ""}
        </Body>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
          {Array.from({ length: block.weeks }, (_, i) => i + 1).map((n) => (
            <Chip key={n} label={n === block.current_week ? `أسبوع ${n} •` : `أسبوع ${n}`} active={n === w} onPress={() => setWeek(n)} />
          ))}
        </ScrollView>
        {!!block.instructions && <Body muted>{block.instructions}</Body>}
      </Card>

      {notes.length > 0 && (
        <Card>
          <Title>ملاحظات المدربة</Title>
          {notes.map((n) => <Body key={n.id}>{n.body}</Body>)}
        </Card>
      )}

      {days.length > 1 && (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
          {days.map((d) => {
            const done = d.items.length > 0 && d.items.every((i) => logOf(i.id));
            return <Chip key={d.id} label={`${done ? "✓ " : ""}${d.title}`} active={d.id === day?.id} onPress={() => setDayId(d.id)} />;
          })}
        </ScrollView>
      )}

      {day && (
        <Card>
          <Title>{day.title}</Title>
          {day.items.map((it) => {
            const log = logOf(it.id);
            return (
              <Pressable key={it.id} accessibilityRole="button"
                onPress={() => router.push({ pathname: "/coaching/log", params: { item: it.id, week: String(w) } })}
                style={({ pressed }) => [s.item, { borderColor: t.line }, pressed && { opacity: 0.6 }]}>
                <View style={{ flex: 1, gap: 2 }}>
                  <Text style={[s.name, { color: t.text }]}>{it.exercise.name}</Text>
                  <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>المستهدف: {planText(it.plan[w - 1])}</Text>
                  {!!it.note && <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>📝 {it.note}</Text>}
                  {log && (
                    <Text style={{ color: t.navy, fontSize: 14, textAlign: "left", writingDirection: "ltr" }}>
                      ✓ {log.reps.map((r, i) => `${formatKg(log.weights[i])}×${r}`).join("  ")}
                    </Text>
                  )}
                </View>
                <Text style={{ color: log ? t.muted : t.navy, fontSize: 15, fontWeight: "600" }}>{log ? "تعديل" : "سجّل"}</Text>
              </Pressable>
            );
          })}
        </Card>
      )}

      <Card>
        <Body muted>التغذية والمراجعة الأسبوعية متاحة حالياً في الموقع (تحتاج الدخول هناك ببريدك).</Body>
        <Button title="افتح طلبي في الموقع" variant="ghost" onPress={() => openSite(`/account/orders/${encodeURIComponent(data.order.order_no)}`)} />
      </Card>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  item: { flexDirection: "row", alignItems: "center", gap: 10, borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 10, minHeight: 56 },
  name: { fontSize: 16, fontWeight: "700", textAlign: "left" },
});
