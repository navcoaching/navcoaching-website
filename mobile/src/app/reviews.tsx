import { FlatList, StyleSheet, Text, View } from "react-native";
import { Body, Card, ErrorText } from "@/components/ui";
import { useContent } from "@/lib/content";
import { useTheme } from "@/lib/theme";

// تقييمات المتدربين المنشورة
export default function Reviews() {
  const t = useTheme();
  const { data, failed } = useContent();
  if (failed && !data) return <View style={{ padding: 16 }}><ErrorText>تحتاج اتصالاً بالإنترنت.</ErrorText></View>;
  if (!data) return null;
  return (
    <FlatList data={data.reviews} keyExtractor={(r) => r.id} contentContainerStyle={s.page}
      ListHeaderComponent={data.testimonials_disclaimer ? <Body muted>{data.testimonials_disclaimer}</Body> : null}
      renderItem={({ item: r }) => (
        <Card>
          {r.rating != null && <Text style={{ fontSize: 16 }}>{"⭐".repeat(r.rating)}</Text>}
          <Body>«{r.body}»</Body>
          <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>{r.name}{r.product ? ` · ${r.product}` : ""}{r.period ? ` · ${r.period}` : ""}</Text>
          {!!r.reply && <Body muted>💬 رد المدربة: {r.reply}</Body>}
        </Card>
      )} />
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 12, paddingBottom: 40 } });
