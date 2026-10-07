import { router } from "expo-router";
import { Image, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Empty, ErrorText } from "@/components/ui";
import { API_URL } from "@/lib/config";
import { riyals, useContent } from "@/lib/content";
import { useTheme } from "@/lib/theme";

// البرامج والباقات (مثل صفحة البرامج في الموقع)
export default function Packages() {
  const t = useTheme();
  const { data, failed } = useContent();
  if (failed && !data) return <View style={s.page}><ErrorText>تحتاج اتصالاً بالإنترنت لعرض البرامج.</ErrorText></View>;
  if (!data) return null;
  return (
    <ScrollView contentContainerStyle={s.page}>
      {!!data.prices_note && <Body muted>{data.prices_note}</Body>}
      {data.products.length === 0 && <Empty>لا توجد برامج منشورة حالياً.</Empty>}
      {data.products.map((p) => {
        const min = Math.min(...p.offers.map((o) => o.price_halalas));
        return (
          <Pressable key={p.slug} onPress={() => router.push(`/packages/${p.slug}`)} accessibilityRole="button"
            style={({ pressed }) => [s.card, { backgroundColor: t.surface, borderColor: p.recommended ? t.navy : t.line }, pressed && { opacity: 0.7 }]}>
            {p.image_id && <Image source={{ uri: `${API_URL}/api/files/media/${p.image_id}` }} style={s.img} accessibilityIgnoresInvertColors />}
            <View style={{ padding: 14, gap: 6 }}>
              {p.recommended && <Text style={{ color: t.navy, fontWeight: "800", fontSize: 13, textAlign: "left" }}>الأكثر طلباً</Text>}
              <Text style={{ color: t.heading, fontSize: 19, fontWeight: "800", textAlign: "left" }}>{p.name}</Text>
              <Body muted>{p.audience}</Body>
              {p.offers.length > 0 && <Text style={{ color: t.text, fontSize: 16, fontWeight: "700", textAlign: "left" }}>تبدأ من {riyals(min)}</Text>}
            </View>
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 14, paddingBottom: 40 },
  card: { borderWidth: 1.5, borderRadius: 16, overflow: "hidden" },
  img: { width: "100%", aspectRatio: 16 / 9 },
});
