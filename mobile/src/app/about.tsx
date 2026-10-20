import { Image, ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Card, ErrorText, Title } from "@/components/ui";
import { API_URL } from "@/lib/config";
import { useContent } from "@/lib/content";
import { useTheme } from "@/lib/theme";

// عن المدربة
export default function About() {
  const t = useTheme();
  const { data, failed } = useContent();
  if (failed && !data) return <View style={s.page}><ErrorText>تحتاج اتصالاً بالإنترنت.</ErrorText></View>;
  if (!data) return null;
  const a = data.about;
  return (
    <ScrollView contentContainerStyle={s.page}>
      {data.about_photos[0] && <Image source={{ uri: `${API_URL}/api/files/media/${data.about_photos[0].id}` }} style={s.photo} accessibilityLabel={data.about_photos[0].alt} />}
      <Card>
        <Title>{a.name}</Title>
        <Body>{a.bio}</Body>
        {a.points?.map((p) => <Text key={p} style={{ color: t.text, fontSize: 15, textAlign: "left" }}>• {p}</Text>)}
      </Card>
      {a.story && a.story.length > 0 && <Card><Title>{a.story_title ?? "قصتي"}</Title>{a.story.map((p, i) => <Body key={i}>{p}</Body>)}</Card>}
      {a.pillars && a.pillars.length > 0 && (
        <Card><Title>{a.pillars_title ?? "كيف أدرب"}</Title>
          {a.pillars.map((p) => <View key={p.title}><Text style={{ color: t.text, fontWeight: "700", textAlign: "left" }}>{p.title}</Text><Body muted>{p.body}</Body></View>)}
        </Card>
      )}
      {a.certs?.length > 0 && <Card><Title>الشهادات والمؤهلات</Title>{a.certs.map((c) => <Text key={c} style={{ color: t.text, fontSize: 15, textAlign: "left" }}>🎓 {c}</Text>)}</Card>}
      {a.experience && a.experience.length > 0 && <Card><Title>{a.experience_title ?? "الخبرة"}</Title>{a.experience.map((e) => <Body key={e}>• {e}</Body>)}</Card>}
      <Body muted>{data.legal.name} · السجل التجاري {data.legal.cr}</Body>
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16, paddingBottom: 48 }, photo: { width: "100%", aspectRatio: 4 / 5, borderRadius: 18 } });
