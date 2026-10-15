import { router } from "expo-router";
import { useState } from "react";
import { Alert, Image, ScrollView, StyleSheet, View } from "react-native";
import { Body, Button, Card, ErrorText, Title } from "@/components/ui";
import { apiAction } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { API_URL } from "@/lib/config";
import { useContent } from "@/lib/content";
import { downloadAndOpen } from "@/lib/download";
import { useApi } from "@/lib/use-api";

type Library = { free_plans: { id: string; slug: string; title: string; has_file: boolean; url: string }[]; booklets: { id: string; title: string; description: string | null; url: string }[] };

// الجداول المجانية (PDF) مثل الموقع: الطلب يحتاج حساباً مجانياً، والتحميل من «ملفاتي». والكتيبات للمشتركين.
export default function FreePlans() {
  const { data: session } = authClient.useSession();
  const { data, failed } = useContent();
  if (failed && !data) return <View style={{ padding: 16 }}><ErrorText>تحتاج اتصالاً بالإنترنت.</ErrorText></View>;
  if (!data) return null;
  return session ? <WithAccount plans={data.free_plans} /> : (
    <ScrollView contentContainerStyle={s.page}>
      <Body muted>يلزم حساب مجاني: ادخل ببريدك وتطلب الجدول وتحمّله.</Body>
      <Button title="الدخول" onPress={() => router.push("/login")} />
      {data.free_plans.map((p) => <PlanCard key={p.slug} p={p} />)}
    </ScrollView>
  );
}

function PlanCard({ p, children }: { p: { slug: string; title: string; summary: string; audience: string | null; image_id: string | null }; children?: React.ReactNode }) {
  return (
    <Card>
      {p.image_id && <Image source={{ uri: `${API_URL}/api/files/media/${p.image_id}` }} style={s.img} />}
      {!!p.audience && <Body muted>{p.audience}</Body>}
      <Title>{p.title}</Title>
      <Body>{p.summary}</Body>
      {children}
    </Card>
  );
}

function WithAccount({ plans }: { plans: { slug: string; title: string; summary: string; audience: string | null; image_id: string | null }[] }) {
  const { data: lib, reload } = useApi<Library>("/library");
  const [busy, setBusy] = useState<string | null>(null);
  async function request(slug: string) {
    const fd = new FormData();
    fd.append("slug", slug);
    setBusy(slug);
    const r = await apiAction("request-free-plan", fd);
    setBusy(null);
    if (r.error) return Alert.alert("تنبيه", r.error);
    await reload();
  }
  async function open(url: string, name: string) {
    setBusy(url);
    await downloadAndOpen(url, name).catch(() => Alert.alert("تعذّر فتح الملف", "الملف غير متاح الآن. حاول لاحقاً."));
    setBusy(null);
  }
  return (
    <ScrollView contentContainerStyle={s.page}>
      {lib && lib.booklets.length > 0 && (
        <Card>
          <Title>كتيباتي</Title>
          {lib.booklets.map((b) => <Button key={b.id} title={`📘 ${b.title}`} variant="ghost" busy={busy === b.url} onPress={() => open(b.url, `${b.title}.pdf`)} />)}
        </Card>
      )}
      {plans.map((p) => {
        const mine = lib?.free_plans.find((m) => m.slug === p.slug);
        return (
          <PlanCard key={p.slug} p={p}>
            {mine ? (
              <Button title={mine.has_file ? "حمّل الجدول (PDF)" : "الملف غير متاح حالياً"} disabled={!mine.has_file} busy={busy === mine.url}
                onPress={() => open(mine.url, `nav-${p.slug}.pdf`)} />
            ) : (
              <Button title="اطلب الجدول مجاناً" variant="ghost" busy={busy === p.slug} onPress={() => request(p.slug)} />
            )}
          </PlanCard>
        );
      })}
    </ScrollView>
  );
}

const s = StyleSheet.create({ page: { padding: 16, gap: 16, paddingBottom: 48 }, img: { width: "100%", aspectRatio: 16 / 9, borderRadius: 12 } });
