import { router } from "expo-router";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Title } from "@/components/ui";
import { useCoachPrograms } from "@/lib/coach-programs";
import { useTheme } from "@/lib/theme";

/** برامج الكوتش ساره المجانية: تظهر عند توفر الإنترنت، وتُنسخ للجهاز بضغطة */
export function CoachPrograms({ imported }: { imported: Set<string> }) {
  const t = useTheme();
  const { programs, failed, retry } = useCoachPrograms();
  if (programs && programs.length === 0) return null;
  return (
    <Card>
      <Title>برامج مجانية من الكوتش ساره</Title>
      {failed && (
        <>
          <Body muted>تحتاج اتصالاً بالإنترنت لعرض البرامج.</Body>
          <Button title="إعادة المحاولة" variant="ghost" onPress={retry} />
        </>
      )}
      {!failed && !programs && <Body muted>جارٍ التحميل…</Body>}
      {programs?.map((p) => (
        <Pressable key={p.id} onPress={() => router.push(`/coach-program/${p.id}`)} accessibilityRole="button"
          style={({ pressed }) => [s.row, { borderColor: t.line }, pressed && { opacity: 0.6 }]}>
          <View style={{ flex: 1, gap: 2 }}>
            <Text style={[s.name, { color: t.text }]}>{p.name}</Text>
            <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }} numberOfLines={2}>
              {p.summary || `${p.days.length} أيام`}
            </Text>
          </View>
          <Text style={{ color: imported.has(p.id) ? t.muted : t.navy, fontSize: 15, fontWeight: "600" }}>
            {imported.has(p.id) ? "مضاف ✓" : "عرض"}
          </Text>
        </Pressable>
      ))}
    </Card>
  );
}

const s = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", gap: 12, borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 10, minHeight: 56 },
  name: { fontSize: 17, fontWeight: "600", textAlign: "left" },
});
