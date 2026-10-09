import { Redirect, router } from "expo-router";
import { useState } from "react";
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { MacroBars } from "@/components/MacroBars";
import { Body, Button, Card, Chip, Empty, ErrorText, IconButton, Title } from "@/components/ui";
import { apiAction, MEAL_ICON, MEAL_KINDS, type MealKind, type Nutrition } from "@/lib/api";
import { useApi } from "@/lib/use-api";
import { useTheme } from "@/lib/theme";

const dayFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" });
const shift = (d: string, n: number) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

// التغذية للمتدرب: أكل اليوم مقابل أهداف المدربة، والجداول، والمكملات (مثل صفحة الموقع)
export default function NutritionScreen() {
  const t = useTheme();
  const [date, setDate] = useState<string | null>(null);
  const [tab, setTab] = useState<"today" | "plans" | "supplements">("today");
  const { data, error, reload } = useApi<{ nutrition: Nutrition | null }>(`/nutrition${date ? `?date=${date}` : ""}`);
  if (error === "login") return <Redirect href="/login" />;
  if (error && !data) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!data) return null;
  const n = data.nutrition;
  if (!n || (!n.target && n.plans.length === 0 && !n.routine)) return <Empty>خطة التغذية تظهر هنا بعد ما تجهّزها المدربة.</Empty>;
  const tg = n.target;

  async function del(id: number) {
    const fd = new FormData();
    fd.append("id", String(id)); fd.append("order_no", n!.order_no);
    const r = await apiAction("delete-food-log", fd);
    if (r.error) Alert.alert("تنبيه", r.error); else reload();
  }

  return (
    <ScrollView contentContainerStyle={s.page}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
        <Chip label="أكل اليوم" active={tab === "today"} onPress={() => setTab("today")} />
        {n.plans.length > 0 && <Chip label="جداولي الغذائية" active={tab === "plans"} onPress={() => setTab("plans")} />}
        {n.routine && <Chip label="المكملات" active={tab === "supplements"} onPress={() => setTab("supplements")} />}
      </ScrollView>

      {tab === "today" && (
        <>
          <View style={s.dateRow}>
            <IconButton name="chevron-forward" label="اليوم السابق" onPress={() => setDate(shift(n.date, -1))} color={t.navy} />
            <Text style={[s.date, { color: t.heading }]}>{n.date === n.today ? "اليوم" : dayFmt.format(Date.parse(`${n.date}T00:00:00Z`))}</Text>
            <IconButton name="chevron-back" label="اليوم التالي" onPress={() => n.date < n.today && setDate(shift(n.date, 1))} color={n.date < n.today ? t.navy : t.line} />
          </View>
          <Card>
            <MacroBars rows={[
              { label: "السعرات", got: n.total.kcal, goal: tg?.kcal ?? null, unit: "" },
              { label: "البروتين", got: n.total.protein, goal: tg?.protein ?? null, unit: "غ" },
              { label: "الكارب", got: n.total.carbs, goal: tg?.carbs ?? null, unit: "غ" },
              { label: "الدهون", got: n.total.fat, goal: tg?.fat ?? null, unit: "غ" },
            ]} />
            {!!tg?.rules && <Body muted>{tg.rules}</Body>}
          </Card>
          {(Object.keys(MEAL_KINDS) as MealKind[]).map((k) => {
            const logs = n.logs.filter((l) => l.kind === k);
            return (
              <Card key={k}>
                <View style={s.head}>
                  <Title>{MEAL_ICON[k]} {MEAL_KINDS[k]}</Title>
                  <Pressable onPress={() => router.push({ pathname: "/nutrition/add", params: { kind: k, date: n.date } })} accessibilityRole="button" hitSlop={10}>
                    <Text style={{ color: t.navy, fontSize: 16, fontWeight: "700" }}>+ أضف</Text>
                  </Pressable>
                </View>
                {logs.map((l) => (
                  <View key={l.id} style={[s.log, { borderColor: t.line }]}>
                    <View style={{ flex: 1 }}>
                      <Text style={{ color: t.text, fontSize: 15, textAlign: "left" }}>{l.name}</Text>
                      <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>{Math.round(l.kcal)} سعرة · ب {l.protein} · ك {l.carbs} · د {l.fat}</Text>
                    </View>
                    <IconButton name="trash-outline" label={`حذف ${l.name}`} color={t.err} onPress={() => del(l.id)} />
                  </View>
                ))}
              </Card>
            );
          })}
        </>
      )}

      {tab === "plans" && n.plans.map((p) => (
        <Card key={p.id}>
          <Title>{p.name}</Title>
          <Body muted>{Math.round(p.total.kcal)} سعرة · بروتين {p.total.protein}غ · كارب {p.total.carbs}غ · دهون {p.total.fat}غ</Body>
          {!!p.notes && <Body>{p.notes}</Body>}
          {p.meals.map((m) => (
            <View key={m.id} style={[s.meal, { borderColor: t.line }]}>
              <Text style={{ color: t.heading, fontSize: 16, fontWeight: "700", textAlign: "left" }}>{MEAL_ICON[m.kind]} {m.title || MEAL_KINDS[m.kind]} · {Math.round(m.total.kcal)} سعرة</Text>
              {m.items.map((it) => (
                <Text key={it.id} style={{ color: t.text, fontSize: 14, textAlign: "left" }}>• {it.food}{it.portion ? ` — ${it.portion}` : ""}</Text>
              ))}
              {!!m.method && <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>{m.method}</Text>}
            </View>
          ))}
        </Card>
      ))}

      {tab === "supplements" && n.routine && (
        <>
          <Card>
            <Title>{n.routine.name}</Title>
            {!!n.routine.intro && <Body>{n.routine.intro}</Body>}
          </Card>
          {n.routine.sections.map((sec) => (
            <Card key={sec.id}>
              <Title>{sec.title}</Title>
              {!!sec.routine && <Body muted>{sec.routine}</Body>}
              {sec.items.map((it) => (
                <View key={it.id} style={[s.meal, { borderColor: t.line }]}>
                  <Text style={{ color: t.heading, fontSize: 16, fontWeight: "700", textAlign: "left" }}>{it.name}</Text>
                  {[it.dose && `الجرعة: ${it.dose}`, it.timing && `التوقيت: ${it.timing}`, it.importance && `الأهمية: ${it.importance}`, it.benefit]
                    .filter(Boolean).map((x) => <Text key={x as string} style={{ color: t.text, fontSize: 14, textAlign: "left" }}>{x}</Text>)}
                </View>
              ))}
            </Card>
          ))}
        </>
      )}
      {tab === "today" && <Button title="تحديث" variant="ghost" onPress={reload} />}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  dateRow: { flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
  date: { fontSize: 17, fontWeight: "700" },
  head: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
  log: { flexDirection: "row", alignItems: "center", borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 6 },
  meal: { borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 8, gap: 2 },
});
