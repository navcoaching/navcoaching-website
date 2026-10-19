import * as Haptics from "expo-haptics";
import { router, Stack, useLocalSearchParams } from "expo-router";
import { useState } from "react";
import { Alert, Linking, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Body, Button, Card, Empty, ErrorText, Title } from "@/components/ui";
import { api, apiAction } from "@/lib/api";
import { planText, useCoaching } from "@/lib/coaching";
import { formatKg, parseNumber } from "@/lib/tracker/logic";
import { useTheme } from "@/lib/theme";

const MAX_SETS = 10;

// تسجيل تمرين من برنامج المدربة: وزن وتكرارات لكل جولة + RIR. نفس قواعد الموقع:
// الجولة الفارغة الوزن تأخذ وزن اللي قبلها، والفارغة التكرارات تأخذ المستهدف.
export default function LogItem() {
  const { item: itemId, week: weekStr } = useLocalSearchParams<{ item: string; week: string }>();
  const week = Number(weekStr) || 1;
  const t = useTheme();
  const { data, reload } = useCoaching();
  const item = data?.days?.flatMap((d) => d.items).find((i) => i.id === itemId);
  const log = data?.logs?.find((l) => l.item === itemId && l.week === week);
  const plan = item?.plan[week - 1];
  const n0 = Math.max(plan?.sets ?? 0, log?.reps.length ?? 0, 1);
  const [weights, setWeights] = useState<string[]>(() => Array.from({ length: n0 }, (_, i) => (log ? formatKg(log.weights[i]) : "")));
  const [reps, setReps] = useState<string[]>(() => Array.from({ length: n0 }, (_, i) => (log?.reps[i] != null ? String(log.reps[i]) : "")));
  const [rir, setRir] = useState(log?.rir != null ? String(log.rir) : "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!data || !item || !data.block) return <Empty>التمرين غير موجود.</Empty>;
  const readOnly = data.block.read_only;

  async function submit(clear = false) {
    setError(null);
    if (!clear) {
      if (weights[0].trim() === "" || parseNumber(weights[0], { max: 1000 }) === null) return setError("اكتب وزن الجولة الأولى بالكيلو (0 لتمارين وزن الجسم).");
      if (weights.some((w) => w.trim() && parseNumber(w, { max: 1000 }) === null)) return setError("الوزن رقم من 0 إلى 1000.");
      if (reps.some((r) => r.trim() && parseNumber(r, { max: 200, integer: true }) === null)) return setError("التكرارات أرقام صحيحة.");
      if (rir.trim() && parseNumber(rir, { max: 10 }) === null) return setError("RIR رقم من 0 إلى 10.");
    }
    const fd = new FormData();
    fd.append("item", itemId);
    fd.append("week", String(week));
    fd.append("order_no", data!.order.order_no);
    if (clear) fd.append("clear", "1");
    else {
      weights.forEach((w) => fd.append("set_weight", w.trim() ? String(parseNumber(w, { max: 1000 })) : ""));
      reps.forEach((r) => fd.append("reps", r.trim() ? String(parseNumber(r, { max: 200, integer: true })) : ""));
      if (rir.trim()) fd.append("rir", String(parseNumber(rir, { max: 10 })));
    }
    setBusy(true);
    const res = await apiAction("log-item", fd);
    setBusy(false);
    if (res.error) return setError(res.error);
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    await reload();
    router.back();
  }

  const set = (arr: string[], i: number, v: string) => arr.map((x, j) => (j === i ? v : x));
  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Stack.Screen options={{ title: item.exercise.name }} />
      <Card>
        <Title>{item.exercise.name}</Title>
        <Body muted>الأسبوع {week} · المستهدف: {planText(plan)}</Body>
        {!!item.note && <Body>📝 {item.note}</Body>}
        {!!item.exercise.instructions && <Body muted>{item.exercise.instructions}</Body>}
        {!!item.exercise.video && <Button title="شاهد طريقة الأداء (فيديو)" variant="ghost" onPress={() => Linking.openURL(item.exercise.video!)} />}
      </Card>
      <Card>
        <View style={s.row}>
          <Text style={[s.col0, s.head, { color: t.muted }]}>#</Text>
          <Text style={[s.col, s.head, { color: t.muted }]}>الوزن (كجم)</Text>
          <Text style={[s.col, s.head, { color: t.muted }]}>التكرارات</Text>
        </View>
        {weights.map((w, i) => (
          <View key={i} style={s.row}>
            <Text style={[s.col0, { color: t.text, fontWeight: "700", fontSize: 16, textAlign: "center" }]}>{i + 1}</Text>
            <TextInput value={w} onChangeText={(v) => setWeights(set(weights, i, v))} editable={!readOnly} keyboardType="decimal-pad"
              placeholder={i === 0 ? "" : "نفس اللي قبلها"} placeholderTextColor={t.muted} accessibilityLabel={`وزن الجولة ${i + 1}`}
              style={[s.col, s.input, { color: t.text, borderColor: t.line, backgroundColor: t.paper }]} />
            <TextInput value={reps[i]} onChangeText={(v) => setReps(set(reps, i, v))} editable={!readOnly} keyboardType="number-pad"
              placeholder={plan?.reps[i] != null ? String(plan.reps[i]) : ""} placeholderTextColor={t.muted} accessibilityLabel={`تكرارات الجولة ${i + 1}`}
              style={[s.col, s.input, { color: t.text, borderColor: t.line, backgroundColor: t.paper }]} />
          </View>
        ))}
        {!readOnly && weights.length < MAX_SETS && (
          <Button title="+ جولة" variant="ghost" onPress={() => { setWeights([...weights, ""]); setReps([...reps, ""]); }} />
        )}
        <View style={{ gap: 6 }}>
          <Text style={{ color: t.text, fontSize: 15, fontWeight: "600", textAlign: "left" }}>RIR (كم تكرار كان باقي عندك؟)</Text>
          <TextInput value={rir} onChangeText={setRir} editable={!readOnly} keyboardType="decimal-pad" placeholder={plan?.rir != null ? String(plan.rir) : ""}
            placeholderTextColor={t.muted} accessibilityLabel="RIR" style={[s.input, { color: t.text, borderColor: t.line, backgroundColor: t.paper }]} />
        </View>
      </Card>
      {error && <ErrorText>{error}</ErrorText>}
      {!readOnly && <Button title="حفظ" busy={busy} onPress={() => submit()} />}
      {!readOnly && <Swap item={itemId} orderNo={data.order.order_no} onDone={reload} />}
      {!readOnly && log && (
        <Button title="حذف التسجيل" variant="ghost" onPress={() => Alert.alert("حذف تسجيل هذا الأسبوع؟", undefined, [
          { text: "إلغاء", style: "cancel" }, { text: "حذف", style: "destructive", onPress: () => submit(true) },
        ])} />
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", alignItems: "center", gap: 8 },
  head: { fontSize: 12, textAlign: "center" },
  col0: { width: 28 },
  col: { flex: 1 },
  input: { minHeight: 46, borderWidth: 1, borderRadius: 10, textAlign: "center", fontSize: 17, writingDirection: "ltr" },
});

type SwapOpt = { id: string; name: string; is_coach_choice: boolean; is_current: boolean };

/** تبديل التمرين ببديل من قائمة المدربة (يصل إشعار للمدربة، ويبقى السجل السابق كما هو) */
function Swap({ item, orderNo, onDone }: { item: string; orderNo: string; onDone: () => Promise<void> | void }) {
  const t = useTheme();
  const [opts, setOpts] = useState<SwapOpt[] | null>(null);
  const [busy, setBusy] = useState(false);
  async function load() {
    setBusy(true);
    const r = await api<{ options: SwapOpt[] }>(`/coaching/swaps?item=${item}`).catch(() => ({ options: [] }));
    setBusy(false);
    setOpts(r.options);
  }
  function pick(o: SwapOpt) {
    Alert.alert(`التبديل إلى ${o.name}؟`, "يصل إشعار للمدربة بالتبديل.", [
      { text: "إلغاء", style: "cancel" },
      { text: "بدّل", onPress: async () => {
        const fd = new FormData();
        fd.append("item", item); fd.append("exercise", o.id); fd.append("order_no", orderNo);
        const r = await apiAction("swap-exercise", fd);
        if (r.error) return Alert.alert("تنبيه", r.error);
        Alert.alert("تم", r.message ?? "تم التبديل.");
        setOpts(null);
        await onDone();
      } },
    ]);
  }
  if (!opts) return <Button title="بدّل التمرين ببديل" variant="ghost" busy={busy} onPress={load} />;
  return (
    <Card>
      <Title>البدائل</Title>
      {opts.length === 0 && <Body muted>لا توجد بدائل لهذا التمرين.</Body>}
      {opts.filter((o) => !o.is_current).map((o) => (
        <Button key={o.id} title={`${o.name}${o.is_coach_choice ? " (اختيار المدربة)" : ""}`} variant="ghost" onPress={() => pick(o)} />
      ))}
      <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>تسجيلاتك السابقة لهذا التمرين تبقى كما هي.</Text>
    </Card>
  );
}
