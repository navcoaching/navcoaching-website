import { router, Stack, useLocalSearchParams } from "expo-router";
import { useEffect, useState } from "react";
import { Alert, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Button, Card, Empty, Field, IconButton } from "@/components/ui";
import { exercise } from "@/lib/exercises";
import { attempt, useScreenData, useTracker } from "@/lib/tracker/context";
import { formatKg, parseNumber } from "@/lib/tracker/logic";
import type { ProgramItem } from "@/lib/tracker/repo";
import { useTheme } from "@/lib/theme";

export default function EditProgram() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const tracker = useTracker();
  const t = useTheme();
  const { data: program, reload } = useScreenData((tr) => tr.getProgram(id), [id]);
  const [name, setName] = useState("");
  useEffect(() => { if (program) setName(program.name); }, [program?.name]);

  if (program === null) return <Empty>البرنامج غير موجود.</Empty>;
  if (!program) return null;

  const run = (fn: () => Promise<unknown>) => attempt(fn).then(reload);

  function confirmArchive() {
    Alert.alert("حذف البرنامج؟", "سجل تمارينك السابقة يبقى محفوظاً.", [
      { text: "إلغاء", style: "cancel" },
      { text: "حذف", style: "destructive", onPress: () => attempt(() => tracker.archiveProgram(id)).then((ok) => ok && router.back()) },
    ]);
  }

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Stack.Screen options={{ title: program.name }} />
      <Field label="اسم البرنامج" value={name} onChangeText={setName} maxLength={80}
        onEndEditing={() => name.trim() !== program.name && run(() => tracker.renameProgram(id, name))} />

      {program.days.map((d) => (
        <Card key={d.id}>
          <View style={s.row}>
            <DayTitle title={d.title} onSave={(v) => run(() => tracker.renameDay(d.id, v))} />
            {program.days.length > 1 && (
              <IconButton name="trash-outline" label={`حذف ${d.title}`} color={t.err} onPress={() =>
                Alert.alert(`حذف ${d.title}؟`, undefined, [
                  { text: "إلغاء", style: "cancel" },
                  { text: "حذف", style: "destructive", onPress: () => run(() => tracker.deleteDay(d.id)) },
                ])} />
            )}
          </View>
          {d.items.length === 0 && <Empty>لا توجد تمارين في هذا اليوم.</Empty>}
          {d.items.map((it, i) => (
            <ItemRow key={it.id} item={it} first={i === 0} last={i === d.items.length - 1}
              onChange={(patch) => run(() => tracker.updateItem(it.id, patch))}
              onMove={(dir) => run(() => tracker.moveItem(it.id, dir))}
              onDelete={() => run(() => tracker.deleteItem(it.id))}
              onSwap={() => router.push({ pathname: "/swap", params: { target: "item", id: it.id, exercise: it.exercise_id } })} />
          ))}
          <Button title="+ أضف تمريناً" variant="ghost" onPress={() => router.push({ pathname: "/exercise-picker", params: { target: "day", id: d.id } })} />
        </Card>
      ))}

      <Button title="+ أضف يوماً" variant="ghost" onPress={() => run(() => tracker.addDay(id))} />
      <Button title="حذف البرنامج" variant="ghost" onPress={confirmArchive} />
    </ScrollView>
  );
}

function DayTitle({ title, onSave }: { title: string; onSave: (v: string) => void }) {
  const t = useTheme();
  const [v, setV] = useState(title);
  useEffect(() => setV(title), [title]);
  return (
    <TextInput value={v} onChangeText={setV} maxLength={60} accessibilityLabel="اسم اليوم"
      onEndEditing={() => v.trim() && v.trim() !== title ? onSave(v) : setV(title)}
      style={[s.dayTitle, { color: t.heading, borderBottomColor: t.line }]} />
  );
}

function ItemRow({ item, first, last, onChange, onMove, onDelete, onSwap }: {
  item: ProgramItem; first: boolean; last: boolean;
  onChange: (patch: { sets?: number; reps?: string; target_weight?: number | null; rest_sec?: number }) => void;
  onMove: (dir: -1 | 1) => void; onDelete: () => void; onSwap: () => void;
}) {
  const t = useTheme();
  const ex = exercise(item.exercise_id);
  return (
    <View style={[s.item, { borderColor: t.line }]}>
      <View style={s.row}>
        <Pressable style={{ flex: 1 }} onPress={() => router.push(`/exercise/${item.exercise_id}`)} accessibilityRole="link">
          <Text style={[s.exName, { color: t.text }]}>{ex.name}</Text>
          {!!ex.muscle && <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>{ex.muscle}</Text>}
        </Pressable>
        <IconButton name="swap-horizontal" label={`بدّل ${ex.name} بتمرين مشابه`} onPress={onSwap} />
        {!first && <IconButton name="arrow-up" label="تحريك للأعلى" onPress={() => onMove(-1)} />}
        {!last && <IconButton name="arrow-down" label="تحريك للأسفل" onPress={() => onMove(1)} />}
        <IconButton name="close" label={`حذف ${ex.name}`} color={t.err} onPress={onDelete} />
      </View>
      <View style={s.fields}>
        <Num label="جولات" value={String(item.sets)} onSave={(v) => { const n = parseNumber(v, { max: 10, integer: true }); if (n) onChange({ sets: n }); }} />
        <Num label="تكرارات" value={item.reps} keyboard="numbers-and-punctuation" onSave={(v) => v.trim() && onChange({ reps: v })} />
        <Num label="وزن (كجم)" value={formatKg(item.target_weight)} placeholder="—"
          onSave={(v) => onChange({ target_weight: v.trim() ? parseNumber(v, { max: 1000 }) : null })} />
        <Num label="راحة (ث)" value={String(item.rest_sec)} onSave={(v) => { const n = parseNumber(v, { max: 600, integer: true }); if (n !== null) onChange({ rest_sec: n }); }} />
      </View>
    </View>
  );
}

function Num({ label, value, onSave, placeholder, keyboard = "decimal-pad" }: {
  label: string; value: string; onSave: (v: string) => void; placeholder?: string; keyboard?: "decimal-pad" | "numbers-and-punctuation";
}) {
  const t = useTheme();
  const [v, setV] = useState(value);
  useEffect(() => setV(value), [value]);
  return (
    <View style={{ flex: 1, gap: 4 }}>
      <Text style={{ color: t.muted, fontSize: 12, textAlign: "center" }}>{label}</Text>
      <TextInput value={v} onChangeText={setV} keyboardType={keyboard} placeholder={placeholder} placeholderTextColor={t.muted}
        accessibilityLabel={label} selectTextOnFocus onEndEditing={() => v !== value && onSave(v)}
        style={[s.num, { color: t.text, borderColor: t.line, backgroundColor: t.paper }]} />
    </View>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", alignItems: "center", gap: 4 },
  dayTitle: { flex: 1, fontSize: 19, fontWeight: "700", minHeight: 44, borderBottomWidth: StyleSheet.hairlineWidth, textAlign: "right" },
  item: { borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 8, gap: 8 },
  exName: { fontSize: 16, fontWeight: "600", textAlign: "left" },
  fields: { flexDirection: "row", gap: 8 },
  num: { minHeight: 44, borderWidth: 1, borderRadius: 10, textAlign: "center", fontSize: 16, writingDirection: "ltr" },
});
