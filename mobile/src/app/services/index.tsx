import { router } from "expo-router";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Empty, ErrorText } from "@/components/ui";
import { useAddons } from "@/lib/addons";
import { useTheme } from "@/lib/theme";

const ROUTE = { program_review: "/services/review", form_check: "/services/form-check", meal_library: "/meals" } as const;
const ICON = { program_review: "📋", form_check: "🎥", meal_library: "🥗" } as const;

// خدمات الكوتش ساره بأسعار رمزية (منتجات منشورة في لوحة الإدارة).
// «وجباتي» محتوى رقمي لا يُباع هنا بالتحويل (Apple 3.1.1): صار ضمن «ناف برو»، فيظهر كرابط بدون سعر.
export default function Services() {
  const t = useTheme();
  const { addons, failed } = useAddons();
  return (
    <ScrollView contentContainerStyle={s.page}>
      {failed && <ErrorText>تحتاج اتصالاً بالإنترنت لعرض الخدمات.</ErrorText>}
      {addons && addons.length === 0 && <Empty>لا توجد خدمات متاحة حالياً.</Empty>}
      {addons?.filter((a) => a.kind !== "meal_library").map((a) => (
        <Pressable key={a.sku} onPress={() => router.push(ROUTE[a.kind])} accessibilityRole="button"
          style={({ pressed }) => [s.card, { backgroundColor: t.surface, borderColor: t.line }, pressed && { opacity: 0.6 }]}>
          <Text style={{ fontSize: 30 }}>{ICON[a.kind]}</Text>
          <View style={{ flex: 1, gap: 4 }}>
            <Text style={[s.name, { color: t.heading }]}>{a.name}</Text>
            {!!a.about && <Body muted>{a.about}</Body>}
          </View>
          <Text style={{ color: t.navy, fontSize: 16, fontWeight: "800" }}>{a.price}</Text>
        </Pressable>
      ))}
      <Pressable onPress={() => router.push("/pro")} accessibilityRole="button"
        style={({ pressed }) => [s.card, { backgroundColor: t.surface, borderColor: t.line }, pressed && { opacity: 0.6 }]}>
        <Text style={{ fontSize: 30 }}>⭐</Text>
        <View style={{ flex: 1, gap: 4 }}>
          <Text style={[s.name, { color: t.heading }]}>ناف برو</Text>
          <Body muted>بدائل الكوتش لكل تمرين + «وجباتي».</Body>
        </View>
      </Pressable>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 12 },
  card: { flexDirection: "row", alignItems: "center", gap: 12, borderWidth: 1, borderRadius: 16, padding: 14 },
  name: { fontSize: 17, fontWeight: "700", textAlign: "left" },
});
