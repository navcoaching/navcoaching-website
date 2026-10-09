import { ScrollView, StyleSheet, View } from "react-native";
import { Body, Card, ErrorText, Title } from "@/components/ui";
import { useContent } from "@/lib/content";

// السياسات: الشروط، الضمان والاسترجاع، الخصوصية، التقييمات
export default function Policies() {
  const { data, failed } = useContent();
  if (failed && !data) return <View style={{ padding: 16 }}><ErrorText>تحتاج اتصالاً بالإنترنت.</ErrorText></View>;
  if (!data) return null;
  return (
    <ScrollView contentContainerStyle={s.page}>
      {data.policies.map((p) => (
        <Card key={p.slug}>
          <Title>{p.title}</Title>
          {p.body.split(/\n+/).filter(Boolean).map((para, i) => <Body key={i}>{para}</Body>)}
        </Card>
      ))}
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16, paddingBottom: 48 } });
