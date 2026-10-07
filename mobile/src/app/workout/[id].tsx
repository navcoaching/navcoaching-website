import * as Haptics from "expo-haptics";
import { Redirect, router, Stack, useLocalSearchParams } from "expo-router";
import { useEffect, useState } from "react";
import { Alert, Keyboard, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { Button, Card, Empty, IconButton } from "@/components/ui";
import { exercise } from "@/lib/exercises";
import { useRestTimer } from "@/lib/rest-timer";
import { attempt, useScreenData, useTracker } from "@/lib/tracker/context";
import { formatDuration, formatKg, parseNumber, parseReps, suggestNext, type SetKind, type Suggestion } from "@/lib/tracker/logic";
import type { PrevSet, WorkoutExercise, WorkoutSet } from "@/lib/tracker/repo";
import { useTheme } from "@/lib/theme";

const DEFAULT_REST = 90;
const KIND_NEXT: Record<SetKind, SetKind> = { normal: "warmup", warmup: "drop", drop: "normal" };
const KIND_LABEL: Record<SetKind, string> = { normal: "جولة", warmup: "جولة إحماء", drop: "دروب سيت" };

export default function WorkoutScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const tracker = useTracker();
  const t = useTheme();
  const timer = useRestTimer();
  const { data: w, reload } = useScreenData((tr) => tr.getWorkout(id), [id]);

  if (w === null) return <Empty>التمرين غير موجود.</Empty>;
  if (!w) return null;
  if (w.finished_at) return <Redirect href={`/history/${id}`} />;

  const run = (fn: () => Promise<unknown>) => attempt(fn).then(async (ok) => { await reload(); return ok; });

  async function complete(ex: WorkoutExercise, set: WorkoutSet, weight: number | null, reps: number | null) {
    const ok = await run(() => tracker.updateSet(set.id, { weight, reps, done: true }));
    if (!ok) return;
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    if (set.kind !== "warmup") timer.start(ex.target?.rest_sec ?? DEFAULT_REST);
  }

  async function finish() {
    Keyboard.dismiss();
    const pending = w!.exercises.reduce((n, e) => n + e.sets.filter((s) => !s.done).length, 0);
    const go = async () => {
      let ok = false;
      await attempt(async () => { await tracker.finishWorkout(id); ok = true; });
      if (ok) { timer.skip(); router.replace(`/workout/summary/${id}`); }
    };
    if (pending > 0) {
      Alert.alert("إنهاء التمرين؟", `${pending} جولات غير مكتملة لن تُحفظ.`, [
        { text: "رجوع", style: "cancel" },
        { text: "إنهاء", onPress: go },
      ]);
    } else go();
  }

  function discard() {
    Alert.alert("حذف التمرين؟", "لن يُحفظ أي شيء من هذا التمرين.", [
      { text: "رجوع", style: "cancel" },
      { text: "حذف", style: "destructive", onPress: () => attempt(() => tracker.discardWorkout(id)).then(() => { timer.skip(); router.back(); }) },
    ]);
  }

  return (
    <View style={{ flex: 1 }}>
      <Stack.Screen options={{ title: w.title, headerRight: () => <Elapsed since={w.started_at} /> }} />
      <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag">
        {w.exercises.length === 0 && <Empty>أضف أول تمرين.</Empty>}
        {w.exercises.map((ex) => (
          <ExerciseBlock key={ex.position} ex={ex}
            onSwap={() => router.push({ pathname: "/swap", params: { target: "workout", id, position: String(ex.position), exercise: ex.exercise_id, inProgram: ex.item_id ? "1" : "0" } })}
            onComplete={(set, wt, rp) => complete(ex, set, wt, rp)}
            onUndo={(set) => run(() => tracker.updateSet(set.id, { done: false }))}
            onSave={(set, patch) => run(() => tracker.updateSet(set.id, patch))}
            onAddSet={() => run(() => tracker.addSet(id, ex.position))}
            onDeleteSet={(set) => run(() => tracker.deleteSet(set.id))} />
        ))}
        <Button title="+ أضف تمريناً" variant="ghost" onPress={() => router.push({ pathname: "/exercise-picker", params: { target: "workout", id } })} />
        <Button title="إنهاء التمرين" onPress={finish} />
        <Pressable onPress={discard} accessibilityRole="button" style={{ minHeight: 44, justifyContent: "center" }}>
          <Text style={{ color: t.err, textAlign: "center", fontSize: 16 }}>حذف التمرين</Text>
        </Pressable>
      </ScrollView>

      {timer.active && (
        <View style={[s.timer, { backgroundColor: t.ink }]} accessibilityLiveRegion="polite">
          <Pressable onPress={() => timer.adjust(-15)} style={s.timerBtn} accessibilityRole="button" accessibilityLabel="أنقص 15 ثانية">
            <Text style={s.timerBtnText}>−15</Text>
          </Pressable>
          <View style={{ alignItems: "center" }}>
            <Text style={{ color: "#a9bad0", fontSize: 13 }}>راحة</Text>
            <Text style={s.timerText}>{formatDuration(timer.remaining)}</Text>
          </View>
          <Pressable onPress={() => timer.adjust(15)} style={s.timerBtn} accessibilityRole="button" accessibilityLabel="زد 15 ثانية">
            <Text style={s.timerBtnText}>+15</Text>
          </Pressable>
          <Pressable onPress={timer.skip} style={s.timerBtn} accessibilityRole="button" accessibilityLabel="تخطي الراحة">
            <Text style={s.timerBtnText}>تخطي</Text>
          </Pressable>
        </View>
      )}
    </View>
  );
}

function Elapsed({ since }: { since: number }) {
  const t = useTheme();
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const iv = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(iv); }, []);
  return <Text style={{ color: t.muted, fontSize: 15, fontVariant: ["tabular-nums"] }}>{formatDuration((now - since) / 1000)}</Text>;
}

function ExerciseBlock({ ex, onSwap, onComplete, onUndo, onSave, onAddSet, onDeleteSet }: {
  ex: WorkoutExercise;
  onSwap: () => void;
  onComplete: (set: WorkoutSet, weight: number | null, reps: number | null) => void;
  onUndo: (set: WorkoutSet) => void;
  onSave: (set: WorkoutSet, patch: { weight?: number | null; reps?: number | null; kind?: SetKind }) => void;
  onAddSet: () => void;
  onDeleteSet: (set: WorkoutSet) => void;
}) {
  const t = useTheme();
  const info = exercise(ex.exercise_id);
  const target = ex.target;
  const targetReps = parseReps(target?.reps);
  const tip = suggestNext(ex.previous, targetReps);
  let normalNo = 0;
  return (
    <Card>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 4 }}>
        <Pressable style={{ flex: 1 }} onPress={() => router.push(`/exercise/${ex.exercise_id}`)} accessibilityRole="link">
          <Text style={[s.exName, { color: t.navy }]}>{info.name}</Text>
        </Pressable>
        {/* التبديل قبل إكمال أي جولة فقط، حتى يبقى السجل صحيحاً */}
        {!ex.sets.some((x) => x.done) && <IconButton name="swap-horizontal" label={`بدّل ${info.name} بتمرين مشابه`} onPress={onSwap} />}
      </View>
      {target && (
        <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>
          الهدف: {target.reps} تكرار{target.weight != null ? ` · ${formatKg(target.weight)} كجم` : ""} · راحة {target.rest_sec} ث
        </Text>
      )}
      {tip && <Text style={{ color: t.navy, fontSize: 14, textAlign: "left" }}>💡 {tipText(tip)}</Text>}
      <View style={s.headRow}>
        <Text style={[s.colSet, s.head, { color: t.muted }]}>#</Text>
        <Text style={[s.colPrev, s.head, { color: t.muted }]}>السابق</Text>
        <Text style={[s.colIn, s.head, { color: t.muted }]}>كجم</Text>
        <Text style={[s.colIn, s.head, { color: t.muted }]}>تكرار</Text>
        <View style={s.colDone} />
      </View>
      {ex.sets.map((set, i) => {
        if (set.kind === "normal") normalNo++;
        const prev: PrevSet | undefined = ex.previous[i];
        return (
          <SetRow key={set.id} set={set} label={set.kind === "normal" ? String(normalNo) : set.kind === "warmup" ? "إ" : "د"}
            prev={prev}
            placeholderWeight={set.kind !== "warmup" && tip ? tip.weight : prev?.weight ?? target?.weight ?? null}
            placeholderReps={set.kind !== "warmup" && tip && tip.reason !== "same" && tip.reason !== "reps" ? tip.reps.min : prev?.reps ?? targetReps?.min ?? null}
            onComplete={(wt, rp) => onComplete(set, wt, rp)} onUndo={() => onUndo(set)}
            onSave={(patch) => onSave(set, patch)} onDelete={() => onDeleteSet(set)} />
        );
      })}
      <Button title="+ جولة" variant="ghost" onPress={onAddSet} />
    </Card>
  );
}

/** نص اقتراح اليوم المبني على آخر جلسة (التدرج المزدوج) */
function tipText(s: Suggestion): string {
  const range = s.reps.min === s.reps.max ? `${s.reps.min}` : `${s.reps.min}-${s.reps.max}`;
  switch (s.reason) {
    case "up": return `وصلت أعلى المدى المرة السابقة: جرّب ${formatKg(s.weight)} كجم × ${range}`;
    case "down": return `التكرارات كانت أقل من المدى: جرّب ${formatKg(s.weight)} كجم × ${range}`;
    case "reps": return `زد تكراراً واحداً على الأقل عن المرة السابقة`;
    default: return `نفس الوزن ${formatKg(s.weight)} كجم، وحاول تزيد تكراراً حتى ${s.reps.max}`;
  }
}

function SetRow({ set, label, prev, placeholderWeight, placeholderReps, onComplete, onUndo, onSave, onDelete }: {
  set: WorkoutSet; label: string; prev?: PrevSet; placeholderWeight: number | null; placeholderReps: number | null;
  onComplete: (weight: number | null, reps: number | null) => void; onUndo: () => void;
  onSave: (patch: { weight?: number | null; reps?: number | null; kind?: SetKind }) => void; onDelete: () => void;
}) {
  const t = useTheme();
  const [weight, setWeight] = useState(formatKg(set.weight));
  const [reps, setReps] = useState(set.reps == null ? "" : String(set.reps));
  useEffect(() => { setWeight(formatKg(set.weight)); setReps(set.reps == null ? "" : String(set.reps)); }, [set.weight, set.reps]);

  const wNum = () => (weight.trim() ? parseNumber(weight, { max: 1000 }) : placeholderWeight);
  const rNum = () => (reps.trim() ? parseNumber(reps, { max: 200, integer: true }) : placeholderReps);

  function saveField(kind: "weight" | "reps") {
    if (kind === "weight") {
      const n = weight.trim() ? parseNumber(weight, { max: 1000 }) : null;
      if (weight.trim() && n === null) { Alert.alert("تنبيه", "الوزن رقم من 0 إلى 1000."); setWeight(formatKg(set.weight)); return; }
      if (n !== set.weight) onSave({ weight: n });
    } else {
      const n = reps.trim() ? parseNumber(reps, { max: 200, integer: true }) : null;
      if (reps.trim() && n === null) { Alert.alert("تنبيه", "التكرارات عدد صحيح من 0 إلى 200."); setReps(set.reps == null ? "" : String(set.reps)); return; }
      if (n !== set.reps) onSave({ reps: n });
    }
  }

  const bg = set.done ? t.cyan + "33" : "transparent";
  return (
    <Pressable onLongPress={() => Alert.alert("حذف الجولة؟", undefined, [
      { text: "إلغاء", style: "cancel" }, { text: "حذف", style: "destructive", onPress: onDelete },
    ])} style={[s.setRow, { backgroundColor: bg }]} accessibilityHint="اضغط مطولاً لحذف الجولة">
      <Pressable onPress={() => onSave({ kind: KIND_NEXT[set.kind] })} style={s.colSet} accessibilityRole="button"
        accessibilityLabel={`${KIND_LABEL[set.kind]} ${label}. اضغط لتغيير النوع`}>
        <Text style={[s.setLabel, { color: set.kind === "normal" ? t.text : t.navy }]}>{label}</Text>
      </Pressable>
      <Text style={[s.colPrev, { color: t.muted, fontSize: 14, textAlign: "center", writingDirection: "ltr" }]} numberOfLines={1}>
        {prev?.weight != null && prev?.reps != null ? `${formatKg(prev.weight)}×${prev.reps}` : "—"}
      </Text>
      <TextInput value={weight} onChangeText={setWeight} onEndEditing={() => saveField("weight")} keyboardType="decimal-pad"
        placeholder={formatKg(placeholderWeight)} placeholderTextColor={t.muted} selectTextOnFocus accessibilityLabel="الوزن بالكيلو"
        style={[s.colIn, s.input, { color: t.text, borderColor: t.line, backgroundColor: t.surface }]} />
      <TextInput value={reps} onChangeText={setReps} onEndEditing={() => saveField("reps")} keyboardType="number-pad"
        placeholder={placeholderReps == null ? "" : String(placeholderReps)} placeholderTextColor={t.muted} selectTextOnFocus accessibilityLabel="التكرارات"
        style={[s.colIn, s.input, { color: t.text, borderColor: t.line, backgroundColor: t.surface }]} />
      <View style={s.colDone}>
        <IconButton name={set.done ? "checkmark-circle" : "checkmark-circle-outline"} color={set.done ? t.navy : t.muted}
          label={set.done ? "إلغاء إكمال الجولة" : "إكمال الجولة"} onPress={() => (set.done ? onUndo() : onComplete(wNum(), rNum()))} />
      </View>
    </Pressable>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 140 },
  exName: { fontSize: 18, fontWeight: "700", textAlign: "left" },
  headRow: { flexDirection: "row", alignItems: "center", gap: 6 },
  head: { fontSize: 12, textAlign: "center" },
  setRow: { flexDirection: "row", alignItems: "center", gap: 6, borderRadius: 10, paddingVertical: 2 },
  colSet: { width: 34, minHeight: 44, alignItems: "center", justifyContent: "center" },
  colPrev: { flex: 1.1 },
  colIn: { flex: 1 },
  colDone: { width: 44, alignItems: "center" },
  setLabel: { fontSize: 16, fontWeight: "700" },
  input: { minHeight: 44, borderWidth: 1, borderRadius: 10, textAlign: "center", fontSize: 17, writingDirection: "ltr" },
  timer: { position: "absolute", left: 12, right: 12, bottom: 24, borderRadius: 18, padding: 12, flexDirection: "row", alignItems: "center", justifyContent: "space-around" },
  timerText: { color: "#ffffff", fontSize: 28, fontWeight: "800", fontVariant: ["tabular-nums"] },
  timerBtn: { minWidth: 56, minHeight: 44, alignItems: "center", justifyContent: "center" },
  timerBtnText: { color: "#eaf2fb", fontSize: 16, fontWeight: "700" },
});
