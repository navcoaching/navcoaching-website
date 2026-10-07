import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, ErrorText } from "@/components/ui";
import { useContent } from "@/lib/content";
import { useTheme } from "@/lib/theme";

// الأسئلة الشائعة (السؤال يفتح جوابه)
export default function Faq() {
  const t = useTheme();
  const { data, failed } = useContent();
  const [open, setOpen] = useState<number | null>(0);
  if (failed && !data) return <View style={{ padding: 16 }}><ErrorText>تحتاج اتصالاً بالإنترنت.</ErrorText></View>;
  if (!data) return null;
  return (
    <ScrollView contentContainerStyle={s.page}>
      {data.faqs.map((f, i) => (
        <View key={i} style={[s.item, { borderColor: t.line, backgroundColor: t.surface }]}>
          <Pressable onPress={() => setOpen(open === i ? null : i)} accessibilityRole="button" accessibilityState={{ expanded: open === i }} style={{ minHeight: 44, justifyContent: "center" }}>
            <Text style={{ color: t.heading, fontSize: 16, fontWeight: "700", textAlign: "left" }}>{open === i ? "−" : "+"} {f.q}</Text>
          </Pressable>
          {open === i && <Body>{f.a}</Body>}
        </View>
      ))}
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 10, paddingBottom: 40 }, item: { borderWidth: 1, borderRadius: 12, paddingHorizontal: 14, paddingVertical: 6, gap: 6 } });
