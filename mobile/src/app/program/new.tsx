import { router } from "expo-router";
import { useState } from "react";
import { ScrollView, StyleSheet } from "react-native";
import { Body, Button, Field } from "@/components/ui";
import { attempt, useTracker } from "@/lib/tracker/context";

export default function NewProgram() {
  const tracker = useTracker();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);

  async function create() {
    setBusy(true);
    let id = "";
    const ok = await attempt(async () => { id = await tracker.createProgram(name); });
    setBusy(false);
    if (ok) router.replace(`/program/${id}`);
  }

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Field label="اسم البرنامج" value={name} onChangeText={setName} placeholder="مثل: علوي / سفلي" autoFocus maxLength={80}
        returnKeyType="done" onSubmitEditing={create} />
      <Body muted>بعدها تضيف الأيام والتمارين.</Body>
      <Button title="إنشاء" busy={busy} disabled={!name.trim()} onPress={create} />
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
