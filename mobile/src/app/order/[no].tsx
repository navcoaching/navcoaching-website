import { File, Paths } from "expo-file-system";
import * as Haptics from "expo-haptics";
import { Redirect, Stack, useLocalSearchParams } from "expo-router";
import * as Sharing from "expo-sharing";
import { useState } from "react";
import { Alert, Linking, Pressable, ScrollView, StyleSheet, Switch, Text, View } from "react-native";
import { Body, Button, Card, Chip, ErrorText, Field, Title } from "@/components/ui";
import { apiAction } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { API_URL } from "@/lib/config";
import { useApi } from "@/lib/use-api";
import { useTheme } from "@/lib/theme";

type Detail = {
  order: { order_no: string; product_name: string; offer_label: string; status: string; status_label: string; category: string; amount: string | null; created_at: string };
  entitled: boolean;
  files: { id: string; title: string; kind: "file" | "link"; url: string; mime: string | null }[];
  checkin: null | { can_submit: boolean; questions: { topic: string; q: string }[];
    history: { id: string; created_at: string; answers: { topic: string; q: string; a: string }[]; reply: string | null; video: string | null; replied_at: string | null }[] };
  review: null | { status: "none" | "pending" | "published" | "rejected" | "hidden"; body?: string; rating?: number | null; consent?: boolean; reply?: string | null };
};
const dateFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { day: "numeric", month: "long" });
const REVIEW_STATUS: Record<string, string> = { pending: "قيد المراجعة", published: "منشور", rejected: "لم يُنشر", hidden: "مخفي" };

// تفاصيل الطلب (مثل صفحة الطلب في الموقع): الملفات، المراجعة الأسبوعية وردود المدربة، والتقييم
export default function OrderDetail() {
  const { no } = useLocalSearchParams<{ no: string }>();
  const t = useTheme();
  const { data, error, reload } = useApi<Detail>(`/orders/${encodeURIComponent(no)}`);
  if (error === "login") return <Redirect href="/login" />;
  if (error && !data) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!data) return null;
  const o = data.order;

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Stack.Screen options={{ title: o.product_name }} />
      <Card>
        <Title>{o.product_name}</Title>
        <Body muted>{o.offer_label} · طلب {o.order_no}{o.amount ? ` · ${o.amount}` : ""}</Body>
        <Text style={{ color: t.navy, fontSize: 16, fontWeight: "700", textAlign: "left" }}>{o.status_label}</Text>
      </Card>

      {data.entitled && (
        <Card>
          <Title>ملفاتي</Title>
          {data.files.length === 0 && <Body muted>تظهر ملفات برنامجك وروابطه هنا أول ما تضيفها المدربة.</Body>}
          {data.files.map((f) => <FileRow key={f.id} f={f} />)}
        </Card>
      )}

      {data.checkin && <Checkin no={o.order_no} c={data.checkin} onDone={reload} />}
      {data.review && <Review no={o.order_no} r={data.review} onDone={reload} />}
    </ScrollView>
  );
}

function FileRow({ f }: { f: Detail["files"][number] }) {
  const t = useTheme();
  const [busy, setBusy] = useState(false);
  async function open() {
    if (f.kind === "link") return Linking.openURL(f.url);
    setBusy(true);
    try {
      // الملف محمي بالجلسة: نحمّله بكوكي الجلسة ثم نفتحه بعارض الجوال (حفظ، طباعة، مشاركة)
      const ext = f.mime === "application/pdf" ? "pdf" : f.mime?.includes("spreadsheet") ? "xlsx" : f.mime?.includes("word") ? "docx" : "bin";
      const dest = new File(Paths.cache, `nav-${f.id.slice(0, 8)}.${ext}`);
      const cookie = await authClient.getCookie();
      const out = await File.downloadFileAsync(`${API_URL}${f.url}`, dest, { headers: cookie ? { Cookie: cookie } : {}, idempotent: true });
      await Sharing.shareAsync(out.uri, { dialogTitle: f.title, mimeType: f.mime ?? undefined });
    } catch {
      Alert.alert("تعذّر فتح الملف", "تأكد من الاتصال وحاول مرة ثانية.");
    } finally {
      setBusy(false);
    }
  }
  return (
    <Pressable onPress={open} disabled={busy} accessibilityRole="button" style={[s.row, { borderColor: t.line }]}>
      <Text style={{ color: t.navy, fontSize: 16, flex: 1, textAlign: "left" }}>{f.kind === "link" ? "🔗" : "📄"} {f.title}</Text>
      <Text style={{ color: t.muted }}>{busy ? "…" : f.kind === "link" ? "فتح" : "تحميل"}</Text>
    </Pressable>
  );
}

function Checkin({ no, c, onDone }: { no: string; c: NonNullable<Detail["checkin"]>; onDone: () => void }) {
  const t = useTheme();
  const [answers, setAnswers] = useState<string[]>(c.questions.map(() => ""));
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; error?: string } | null>(null);
  async function send() {
    const fd = new FormData();
    fd.append("order_no", no);
    c.questions.forEach((q, i) => { fd.append("topic", q.topic); fd.append("q", q.q); fd.append("a", answers[i]); });
    setBusy(true);
    const r = await apiAction("submit-checkin", fd);
    setBusy(false);
    if (r.error) return setMsg({ error: r.error });
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    setMsg({ ok: r.message }); setAnswers(c.questions.map(() => "")); onDone();
  }
  return (
    <Card>
      <Title>المراجعة الأسبوعية</Title>
      {c.can_submit && c.questions.map((q, i) => (
        <Field key={i} label={`${q.topic ? `${q.topic}: ` : ""}${q.q}`} value={answers[i]} multiline maxLength={1000}
          onChangeText={(v) => setAnswers(answers.map((x, j) => (j === i ? v : x)))} style={{ minHeight: 70, textAlignVertical: "top" }} />
      ))}
      {c.can_submit && <Body muted>لا تكتب تفاصيل طبية حساسة إلا إذا كانت ضرورية لبرنامجك.</Body>}
      {msg?.error && <ErrorText>{msg.error}</ErrorText>}
      {msg?.ok && <Body>{msg.ok}</Body>}
      {c.can_submit && <Button title="أرسل المراجعة" busy={busy} disabled={answers.every((a) => !a.trim())} onPress={send} />}
      {c.history.map((h) => (
        <View key={h.id} style={[s.hist, { borderColor: t.line }]}>
          <Text style={{ color: t.heading, fontWeight: "700", textAlign: "left" }}>
            مراجعة {dateFmt.format(new Date(h.created_at))} — {h.replied_at ? "وصل الرد ✓" : "بانتظار الرد"}
          </Text>
          {h.answers.map((a, i) => <Text key={i} style={{ color: t.muted, fontSize: 14, textAlign: "left" }}>{a.topic || a.q}: {a.a || "—"}</Text>)}
          {!!h.reply && <Text style={{ color: t.text, fontSize: 15, textAlign: "left" }}>💬 رد المدربة: {h.reply}</Text>}
          {!!h.video && <Button title="🎥 شاهد رد المدربة بالفيديو" variant="ghost" onPress={() => Linking.openURL(h.video!)} />}
        </View>
      ))}
    </Card>
  );
}

function Review({ no, r, onDone }: { no: string; r: NonNullable<Detail["review"]>; onDone: () => void }) {
  const t = useTheme();
  const [rating, setRating] = useState(0);
  const [body, setBody] = useState("");
  const [mode, setMode] = useState<"full" | "first" | "anon">("first");
  const [consent, setConsent] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (r.status !== "none") {
    return (
      <Card>
        <Title>تقييمك</Title>
        <Body muted>الحالة: {REVIEW_STATUS[r.status] ?? r.status}{r.consent ? "" : " (يظهر للمدربة فقط)"}</Body>
        <Body>«{r.body}»</Body>
        {!!r.reply && <Body>💬 رد المدربة: {r.reply}</Body>}
      </Card>
    );
  }
  async function send() {
    const fd = new FormData();
    fd.append("order_no", no); fd.append("rating", rating ? String(rating) : ""); fd.append("body", body);
    fd.append("display_mode", mode); if (consent) fd.append("consent", "on");
    setBusy(true); setError(null);
    const res = await apiAction("submit-review", fd);
    setBusy(false);
    if (res.error) return setError(res.error);
    onDone();
  }
  return (
    <Card>
      <Title>قيّم تجربتك</Title>
      <View style={{ flexDirection: "row", gap: 4 }}>
        {[1, 2, 3, 4, 5].map((n) => (
          <Pressable key={n} onPress={() => setRating(n)} accessibilityRole="button" accessibilityLabel={`${n} من 5`}
            style={{ minWidth: 44, minHeight: 44, alignItems: "center", justifyContent: "center" }}>
            <Text style={{ fontSize: 28, opacity: n <= rating ? 1 : 0.3 }}>⭐</Text>
          </Pressable>
        ))}
      </View>
      <Field label="تجربتك (10 أحرف على الأقل)" value={body} onChangeText={setBody} multiline maxLength={1500} style={{ minHeight: 100, textAlignVertical: "top" }} />
      <Text style={{ color: t.text, fontWeight: "600", textAlign: "left" }}>كيف يظهر اسمك؟</Text>
      <View style={{ flexDirection: "row", gap: 8, flexWrap: "wrap" }}>
        <Chip label="الاسم الأول" active={mode === "first"} onPress={() => setMode("first")} />
        <Chip label="الاسم كامل" active={mode === "full"} onPress={() => setMode("full")} />
        <Chip label="بدون اسم" active={mode === "anon"} onPress={() => setMode("anon")} />
      </View>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>
        <Switch value={consent} onValueChange={setConsent} accessibilityLabel="أوافق على نشر التقييم" />
        <Text style={{ color: t.text, flex: 1, textAlign: "left" }}>أوافق على نشر تقييمي في الموقع</Text>
      </View>
      {error && <ErrorText>{error}</ErrorText>}
      <Button title="أرسل التقييم" busy={busy} disabled={body.trim().length < 10} onPress={send} />
    </Card>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  row: { flexDirection: "row", alignItems: "center", gap: 8, borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 10, minHeight: 44 },
  hist: { borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 8, gap: 4 },
});
