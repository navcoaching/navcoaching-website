import { router } from "expo-router";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Card, ErrorText, Title } from "@/components/ui";
import { useContent } from "@/lib/content";
import { useTheme } from "@/lib/theme";

const LINKS = [
  { href: "/packages", icon: "💪", title: "برامج المتابعة", sub: "الباقات والأسعار والاشتراك" },
  { href: "/free-plans", icon: "📄", title: "الجداول المجانية", sub: "جداول PDF من الكوتش ساره" },
  { href: "/calculator", icon: "🧮", title: "حاسبة السعرات", sub: "سعراتك اليومية وتوازن الطاقة" },
  { href: "/services", icon: "🎯", title: "خدمات الكوتش", sub: "مراجعة جدولك وتصحيح الأداء" },
  { href: "/about", icon: "👩‍🏫", title: "عن المدربة", sub: "الشهادات والخبرة" },
  { href: "/reviews", icon: "⭐", title: "تقييمات المتدربين", sub: "تجارب حقيقية" },
  { href: "/faq", icon: "❓", title: "الأسئلة الشائعة", sub: "" },
  { href: "/policies", icon: "📜", title: "السياسات", sub: "الشروط والخصوصية والضمان" },
] as const;

// اكتشف: صفحات الموقع العامة داخل التطبيق
export default function Explore() {
  const t = useTheme();
  const { data, failed } = useContent();
  return (
    <ScrollView contentContainerStyle={s.page} contentInsetAdjustmentBehavior="automatic">
      {failed && !data && <ErrorText>تحتاج اتصالاً بالإنترنت لعرض المحتوى.</ErrorText>}
      {data && (
        <View style={[s.hero, { backgroundColor: t.ink }]}>
          <Text style={{ color: "#4cc5ed", fontSize: 13, fontWeight: "700", textAlign: "left" }}>{data.hero.eyebrow}</Text>
          <Text style={{ color: "#fff", fontSize: 24, fontWeight: "800", textAlign: "left" }}>{data.hero.title} {data.hero.title_tail}</Text>
          <Text style={{ color: "#a9bad0", fontSize: 15, lineHeight: 22, textAlign: "left" }}>{data.hero.lead}</Text>
          {data.badges.length > 0 && <Text style={{ color: "#eaf2fb", fontSize: 13, textAlign: "left" }}>{data.badges.join(" · ")}</Text>}
        </View>
      )}
      {LINKS.map((l) => (
        <Pressable key={l.href} onPress={() => router.push(l.href)} accessibilityRole="button"
          style={({ pressed }) => [s.link, { backgroundColor: t.surface, borderColor: t.line }, pressed && { opacity: 0.6 }]}>
          <Text style={{ fontSize: 26 }}>{l.icon}</Text>
          <View style={{ flex: 1 }}>
            <Text style={{ color: t.heading, fontSize: 17, fontWeight: "700", textAlign: "left" }}>{l.title}</Text>
            {!!l.sub && <Text style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>{l.sub}</Text>}
          </View>
          <Text style={{ color: t.muted, fontSize: 18 }}>‹</Text>
        </Pressable>
      ))}
      {data && data.why.length > 0 && (
        <Card>
          <Title>ليش Nav Coaching</Title>
          {data.why.map((w) => <View key={w.title} style={{ gap: 2 }}><Text style={{ color: t.text, fontWeight: "700", textAlign: "left" }}>{w.title}</Text><Body muted>{w.body}</Body></View>)}
        </Card>
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 12, paddingBottom: 40 },
  hero: { borderRadius: 18, padding: 18, gap: 8 },
  link: { flexDirection: "row", alignItems: "center", gap: 12, borderWidth: 1, borderRadius: 14, padding: 14, minHeight: 64 },
});
