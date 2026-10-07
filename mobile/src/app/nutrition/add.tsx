import * as Haptics from "expo-haptics";
import { router, Stack, useLocalSearchParams } from "expo-router";
import { useEffect, useMemo, useState } from "react";
import { FlatList, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Chip, Empty, ErrorText, Field, Title } from "@/components/ui";
import { apiAction, siteApi, MEAL_KINDS, type MealKind, type Nutrition, type ReadyMeal } from "@/lib/api";
import { parseNumber } from "@/lib/tracker/logic";
import { useApi } from "@/lib/use-api";
import { useTheme } from "@/lib/theme";

type LocalFood = { id: string; name_ar: string; name_en: string | null; kcal_100: number; protein_100: number; carbs_100: number; fat_100: number; serving_g: number | null; serving_label: string | null };
type ExtFood = { id: string; name: string; brand: string | null; description: string };
type Picked = { source: "local"; food: LocalFood } | { source: "fatsecret"; food: ExtFood };

// إضافة أكل لوجبة: من الوجبات الجاهزة (جداولي وقوالب المدربة)، أو بحث بالغرام، أو إدخال حر. نفس عمليات الموقع.
export default function AddFood() {
  const { kind: k, date } = useLocalSearchParams<{ kind: MealKind; date: string }>();
  const t = useTheme();
  const { data } = useApi<{ nutrition: Nutrition | null }>(`/nutrition?date=${date}`);
  const [kind, setKind] = useState<MealKind>(k in MEAL_KINDS ? k : "breakfast");
  const [mode, setMode] = useState<"ready" | "search" | "free">("ready");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const n = data?.nutrition;

  async function send(action: string, fields: Record<string, string>) {
    if (!n) return;
    setError(null); setBusy(true);
    const fd = new FormData();
    fd.append("order_no", n.order_no); fd.append("date", date); fd.append("kind", kind);
    for (const [key, v] of Object.entries(fields)) fd.append(key, v);
    const r = await apiAction(action, fd);
    setBusy(false);
    if (r.error) return setError(r.error);
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    router.back();
  }

  if (!n) return null;
  return (
    <View style={{ flex: 1 }}>
      <Stack.Screen options={{ title: `أضف إلى ${MEAL_KINDS[kind]}` }} />
      <View style={{ padding: 16, paddingBottom: 0, gap: 10 }}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
          {(Object.keys(MEAL_KINDS) as MealKind[]).map((m) => <Chip key={m} label={MEAL_KINDS[m]} active={kind === m} onPress={() => setKind(m)} />)}
        </ScrollView>
        <View style={{ flexDirection: "row", gap: 8 }}>
          <Chip label="وجبات جاهزة" active={mode === "ready"} onPress={() => setMode("ready")} />
          <Chip label="بحث بالغرام" active={mode === "search"} onPress={() => setMode("search")} />
          <Chip label="إدخال حر" active={mode === "free"} onPress={() => setMode("free")} />
        </View>
        {error && <ErrorText>{error}</ErrorText>}
      </View>
      {mode === "ready" && <Ready meals={n.ready} kind={kind} busy={busy} onPick={(m) => send("log-food", { meal: m.id })} />}
      {mode === "search" && <Search busy={busy} onLog={(p, grams) => send("log-food-grams", { source: p.source, food: p.food.id, grams })} />}
      {mode === "free" && <Free busy={busy} onSave={(f) => send("log-food", f)} />}
    </View>
  );

}


function Ready({ meals, kind, busy, onPick }: { meals: ReadyMeal[]; kind: MealKind; busy: boolean; onPick: (m: ReadyMeal) => void }) {
  const t = useTheme();
  const list = useMemo(() => [...meals].sort((a, b) => Number(b.kind === kind) - Number(a.kind === kind) || Number(b.own) - Number(a.own)), [meals, kind]);
  return (
    <FlatList data={list} keyExtractor={(m) => m.id} contentContainerStyle={{ padding: 16, gap: 8 }}
      ListEmptyComponent={<Empty>ما فيه وجبات جاهزة بعد. استخدم البحث أو الإدخال الحر.</Empty>}
      renderItem={({ item }) => (
        <Pressable disabled={busy} onPress={() => onPick(item)} accessibilityRole="button"
          style={({ pressed }) => [s.row, { borderColor: t.line, backgroundColor: t.surface }, pressed && { opacity: 0.6 }]}>
          <Text style={{ color: t.text, fontSize: 15, fontWeight: "600", textAlign: "left" }}>{item.own ? "⭐ " : ""}{item.label}</Text>
          <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>{Math.round(item.kcal)} سعرة · ب {item.protein} · ك {item.carbs} · د {item.fat}</Text>
        </Pressable>
      )} />
  );
}

function Search({ busy, onLog }: { busy: boolean; onLog: (p: Picked, grams: string) => void }) {
  const t = useTheme();
  const [q, setQ] = useState("");
  const [res, setRes] = useState<{ local: LocalFood[]; external: ExtFood[] } | null>(null);
  const [picked, setPicked] = useState<Picked | null>(null);
  const [grams, setGrams] = useState("");
  useEffect(() => {
    if (q.trim().length < 2) { setRes(null); return; }
    const h = setTimeout(() => {
      // واجهة البحث في الموقع نفسها (قاعدة أكل الموقع ثم FatSecret إن كان مفعّلاً)
      siteApi<{ local: LocalFood[]; external: ExtFood[] }>(`/api/foods/search?q=${encodeURIComponent(q.trim())}`).then(setRes).catch(() => setRes({ local: [], external: [] }));
    }, 350);
    return () => clearTimeout(h);
  }, [q]);
  if (picked) {
    const g = parseNumber(grams, { max: 3000 }) ?? 0;
    const per = picked.source === "local" ? picked.food : null;
    return (
      <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }} keyboardShouldPersistTaps="handled">
        <Card>
          <Title>{picked.source === "local" ? picked.food.name_ar : picked.food.name}</Title>
          {per ? <Body muted>لكل 100غ: {Math.round(per.kcal_100)} سعرة · ب {per.protein_100} · ك {per.carbs_100} · د {per.fat_100}</Body>
            : <Body muted>{picked.source === "fatsecret" ? picked.food.description : ""}</Body>}
          {per?.serving_g && <Body muted>الحصة: {per.serving_label ?? ""} {per.serving_g}غ</Body>}
          <Field label="الكمية بالغرام" value={grams} onChangeText={setGrams} keyboardType="decimal-pad" autoFocus style={{ textAlign: "center", writingDirection: "ltr" }} />
          {per && g > 0 && <Body>= {Math.round((per.kcal_100 * g) / 100)} سعرة · ب {Math.round(per.protein_100 * g) / 100} · ك {Math.round(per.carbs_100 * g) / 100} · د {Math.round(per.fat_100 * g) / 100}</Body>}
          <Button title="أضف" busy={busy} disabled={g < 1} onPress={() => onLog(picked, String(g))} />
          <Button title="رجوع للبحث" variant="ghost" onPress={() => setPicked(null)} />
        </Card>
      </ScrollView>
    );
  }
  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 8 }} keyboardShouldPersistTaps="handled">
      <Field label="ابحث عن صنف (عربي أو إنجليزي)" value={q} onChangeText={setQ} autoCorrect={false} />
      {res && res.local.length === 0 && res.external.length === 0 && <Empty>لا توجد نتائج.</Empty>}
      {res?.local.map((f) => (
        <Pressable key={f.id} onPress={() => { setPicked({ source: "local", food: f }); setGrams(f.serving_g ? String(f.serving_g) : ""); }}
          style={[s.row, { borderColor: t.line, backgroundColor: t.surface }]} accessibilityRole="button">
          <Text style={{ color: t.text, fontSize: 15, fontWeight: "600", textAlign: "left" }}>{f.name_ar}</Text>
          <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>{Math.round(f.kcal_100)} سعرة لكل 100غ</Text>
        </Pressable>
      ))}
      {res?.external.map((f) => (
        <Pressable key={`x${f.id}`} onPress={() => setPicked({ source: "fatsecret", food: f })}
          style={[s.row, { borderColor: t.line, backgroundColor: t.surface }]} accessibilityRole="button">
          <Text style={{ color: t.text, fontSize: 15, fontWeight: "600", textAlign: "left" }}>{f.name}{f.brand ? ` (${f.brand})` : ""}</Text>
          <Text style={{ color: t.muted, fontSize: 12, textAlign: "left" }} numberOfLines={1}>{f.description}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

function Free({ busy, onSave }: { busy: boolean; onSave: (f: Record<string, string>) => void }) {
  const [name, setName] = useState("");
  const [p, setP] = useState(""), [c, setC] = useState(""), [f, setF] = useState("");
  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }} keyboardShouldPersistTaps="handled">
      <Field label="اسم الأكلة" value={name} onChangeText={setName} maxLength={160} />
      <View style={{ flexDirection: "row", gap: 8 }}>
        <View style={{ flex: 1 }}><Field label="بروتين (غ)" value={p} onChangeText={setP} keyboardType="decimal-pad" /></View>
        <View style={{ flex: 1 }}><Field label="كارب (غ)" value={c} onChangeText={setC} keyboardType="decimal-pad" /></View>
        <View style={{ flex: 1 }}><Field label="دهون (غ)" value={f} onChangeText={setF} keyboardType="decimal-pad" /></View>
      </View>
      <Button title="أضف" busy={busy} disabled={!name.trim()} onPress={() => onSave({ name: name.trim(), protein: p || "0", carbs: c || "0", fat: f || "0" })} />
    </ScrollView>
  );
}

const s = StyleSheet.create({ row: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 2 } });
