import { router, useLocalSearchParams } from "expo-router";
import { ScrollView, StyleSheet } from "react-native";
import { Body, Button, Card, Title } from "@/components/ui";
import { RecordsList, StatsRow } from "@/components/WorkoutStats";
import { useScreenData } from "@/lib/tracker/context";

export default function WorkoutDone() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { data: w } = useScreenData((tr) => tr.summary(id), [id]);
  if (!w) return null;
  return (
    <ScrollView contentContainerStyle={s.page}>
      <Card>
        <Title>{w.title}</Title>
        <StatsRow s={w} />
      </Card>
      {w.records.length > 0 ? (
        <Card>
          <Title>أرقام قياسية جديدة</Title>
          <RecordsList s={w} />
        </Card>
      ) : (
        <Body muted>كل تمرين تسجّله يقرّبك من هدفك. استمر.</Body>
      )}
      <Button title="تم" onPress={() => router.dismissTo("/history")} />
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16 } });
