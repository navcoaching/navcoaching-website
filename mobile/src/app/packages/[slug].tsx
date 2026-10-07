import { Stack, useLocalSearchParams } from "expo-router";
import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Chip, Empty, Title } from "@/components/ui";
import { riyals, useContent } from "@/lib/content";
import { openSite } from "@/lib/links";
import { useTheme } from "@/lib/theme";

// تفاصيل الباقة: المشمول وغير المشمول، المدد والأسعار، والطلب
export default function PackageDetail() {
  const { slug } = useLocalSearchParams<{ slug: string }>();
  const t = useTheme();
  const { data } = useContent();
  const p = data?.products.find((x) => x.slug === slug);
  const [sku, setSku] = useState<string | null>(null);
  if (!data) return null;
  if (!p) return <Empty>البرنامج غير متاح.</Empty>;
  const offer = p.offers.find((o) => o.sku === sku) ?? p.offers[0];

  return (
    <ScrollView contentContainerStyle={s.page}>
      <Stack.Screen options={{ title: p.name }} />
      <Card>
        <Title>{p.name}</Title>
        <Body muted>{p.audience}</Body>
        {p.items.map((it, i) => (
          <Text key={i} style={{ color: it.included ? t.text : t.muted, fontSize: 15, textAlign: "left", textDecorationLine: it.included ? "none" : "line-through" }}>
            {it.included ? "✓" : "✗"} {it.text}
          </Text>
        ))}
        {!!p.note && <Body muted>{p.note}</Body>}
      </Card>
      {p.offers.length > 0 && (
        <Card>
          <Title>المدة والسعر</Title>
          <View style={{ flexDirection: "row", flexWrap: "wrap", gap: 8 }}>
            {p.offers.map((o) => <Chip key={o.sku} label={`${o.label} · ${riyals(o.price_halalas)}`} active={o.sku === offer.sku} onPress={() => setSku(o.sku)} />)}
          </View>
          {!!data.prices_note && <Body muted>{data.prices_note}</Body>}
          <Button title={`اطلب ${offer.label}`} onPress={() => openSite(`/checkout/${offer.sku}`)} />
          <Body muted>الطلب يتضمن استبياناً قصيراً عن هدفك ومستواك، والدفع بالتحويل البنكي.</Body>
        </Card>
      )}
      {(p.delivery || p.requirements || p.policy_note) && (
        <Card>
          {!!p.delivery && <><Title>كيف تستلم برنامجك</Title><Body>{p.delivery}</Body></>}
          {!!p.requirements && <><Title>المطلوب منك</Title><Body>{p.requirements}</Body></>}
          {!!p.policy_note && <><Title>الدفع والاسترجاع</Title><Body>{p.policy_note}</Body></>}
        </Card>
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16, paddingBottom: 48 } });
