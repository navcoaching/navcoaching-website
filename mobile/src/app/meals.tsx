import { Redirect, router } from "expo-router";
import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Chip, Empty, ErrorText, Title } from "@/components/ui";
import { MEAL_ICON, MEAL_KINDS, type MealKind } from "@/lib/api";
import { useAddons } from "@/lib/addons";
import { authClient } from "@/lib/auth-client";
import { useApi } from "@/lib/use-api";
import { useTheme } from "@/lib/theme";
import { openSite } from "@/lib/links";

type Meal = { id: string; plan_name: string; kind: MealKind; title: string; protein: number; carbs: number; fat: number; kcal: number; method: string | null; items: { food: string; portion: string | null }[] };

// «وجباتي»: وجبات قوالب التغذية التي تصممها المدربة (للمشتركين، أو لمن اشترك في «وجباتي»)
export default function Meals() {
  const { data: session } = authClient.useSession();
  if (!session) return <Locked />;
  return <MealsList />;
}

function MealsList() {
  const t = useTheme();
  const { data, error } = useApi<{ access: boolean; meals: Meal[] }>("/meals");
  const [kind, setKind] = useState<MealKind | null>(null);
  if (error === "login") return <Redirect href="/login" />;
  if (error && !data) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!data) return null;
  if (!data.access) return <Locked />;
  const list = data.meals.filter((m) => !kind || m.kind === kind);
  return (
    <ScrollView contentContainerStyle={s.page}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
        <Chip label="الكل" active={!kind} onPress={() => setKind(null)} />
        {(Object.keys(MEAL_KINDS) as MealKind[]).map((k) => <Chip key={k} label={`${MEAL_ICON[k]} ${MEAL_KINDS[k]}`} active={kind === k} onPress={() => setKind(k)} />)}
      </ScrollView>
      {list.length === 0 && <Empty>لا توجد وجبات بعد.</Empty>}
      {list.map((m) => (
        <Card key={m.id}>
          <Title>{MEAL_ICON[m.kind]} {m.title}</Title>
          <Body muted>{m.kcal} سعرة · بروتين {m.protein}غ · كارب {m.carbs}غ · دهون {m.fat}غ</Body>
          {m.items.map((it, i) => <Text key={i} style={{ color: t.text, fontSize: 15, textAlign: "left" }}>• {it.food}{it.portion ? ` — ${it.portion}` : ""}</Text>)}
          {!!m.method && <Body muted>{m.method}</Body>}
        </Card>
      ))}
    </ScrollView>
  );
}

function Locked() {
  const { addons } = useAddons();
  const a = addons?.find((x) => x.kind === "meal_library");
  return (
    <ScrollView contentContainerStyle={s.page}>
      <Card>
        <Title>🥗 وجباتي</Title>
        <Body>وجبات تصممها الكوتش ساره بمقاديرها وسعراتها وطريقة تحضيرها، فطور وغداء وعشاء وسناك.</Body>
        <Body muted>متاحة لمشتركي المتابعة.{a ? ` والاشتراك المنفصل فيها (${a.price}) يتوفر داخل التطبيق قريباً.` : ""}</Body>
        <Button title="شوف برامج المتابعة" variant="ghost" onPress={() => openSite("/programs")} />
      </Card>
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16, paddingBottom: 48 } });
