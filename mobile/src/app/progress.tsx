import * as Haptics from "expo-haptics";
import { Redirect } from "expo-router";
import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { LineChart } from "@/components/Charts";
import { Body, Button, Card, ErrorText, Field, Title } from "@/components/ui";
import { apiAction, type Progress } from "@/lib/api";
import { formatKg, parseNumber } from "@/lib/tracker/logic";
import { useApi } from "@/lib/use-api";
import { useTheme } from "@/lib/theme";

const short = (d: string) => `${Number(d.slice(8, 10))}/${Number(d.slice(5, 7))}`;

// التقدم للمتدرب (مثل صفحة «التقدم» في الموقع): الوزن، القياسات، الخطوات، والأرقام القياسية
export default function ProgressScreen() {
  const t = useTheme();
  const { data, error, reload } = useApi<{ progress: Progress }>("/progress");
  const [kg, setKg] = useState("");
  const [m, setM] = useState({ chest: "", waist: "", hips: "", thigh: "" });
  const [steps, setSteps] = useState("");
  const [msg, setMsg] = useState<{ ok?: string; error?: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  if (error === "login") return <Redirect href="/login" />;
  if (error && !data) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!data) return null;
  const p = data.progress;

  async function send(name: string, fields: Record<string, string>) {
    setBusy(name); setMsg(null);
    const fd = new FormData();
    for (const [k, v] of Object.entries(fields)) fd.append(k, v);
    if (p.order_no) fd.append("order_no", p.order_no);
    const r = await apiAction(name, fd);
    setBusy(null);
    if (r.error) return setMsg({ error: r.error });
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    setMsg({ ok: r.message ?? "تم الحفظ." });
    setKg(""); setM({ chest: "", waist: "", hips: "", thigh: "" }); setSteps("");
    reload();
  }

  const weights = p.body.weights.slice(-30);
  const lastM = p.body.measurements[p.body.measurements.length - 1];
  const wk = p.steps ? Math.max(1, p.steps.current_week) : 0;
  const stepsThisWeek = p.steps?.logs.find((x) => x.week_no === wk)?.total;
  const records = [...p.records].sort((a, b) => Number(b.status === "new") - Number(a.status === "new") || b.oneRm - a.oneRm);

  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      {msg?.error && <ErrorText>{msg.error}</ErrorText>}
      {msg?.ok && <Text style={{ color: t.navy, textAlign: "center", fontSize: 15 }}>{msg.ok}</Text>}

      <Card>
        <Title>وزن الجسم</Title>
        {weights.length >= 2 && <LineChart label="الوزن" unit="كجم" points={weights.map((w) => ({ x: short(w.logged_on), y: w.kg }))} />}
        {weights.length === 1 && <Body muted>آخر وزن: {weights[0].kg} كجم</Body>}
        <Field label={`وزن اليوم (${short(p.today)}) بالكيلو`} value={kg} onChangeText={setKg} keyboardType="decimal-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />
        <Button title="حفظ الوزن" busy={busy === "log-weight"} disabled={parseNumber(kg, { max: 350 }) === null}
          onPress={() => send("log-weight", { date: p.today, kg: String(parseNumber(kg, { max: 350 })) })} />
      </Card>

      <Card>
        <Title>القياسات (سم)</Title>
        {lastM && <Body muted>آخر قياس {short(lastM.measured_on)}: الصدر {lastM.chest ?? "—"} · الخصر {lastM.waist ?? "—"} · الورك {lastM.hips ?? "—"} · الفخذ {lastM.thigh ?? "—"}</Body>}
        <View style={s.grid}>
          {([["chest", "الصدر"], ["waist", "الخصر"], ["hips", "الورك"], ["thigh", "الفخذ"]] as const).map(([k, label]) => (
            <View key={k} style={{ width: "47%" }}>
              <Field label={label} value={m[k]} onChangeText={(v) => setM({ ...m, [k]: v })} keyboardType="decimal-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />
            </View>
          ))}
        </View>
        <Button title="حفظ القياسات" busy={busy === "log-measurements"} disabled={!Object.values(m).some((v) => v.trim())}
          onPress={() => send("log-measurements", { date: p.today, ...Object.fromEntries(Object.entries(m).map(([k, v]) => [k, v.trim() ? String(parseNumber(v, { max: 300 }) ?? v) : ""])) })} />
      </Card>

      {p.steps && !p.steps.read_only && (
        <Card>
          <Title>خطوات الأسبوع {wk}</Title>
          <Body muted>الهدف الأسبوعي: {p.steps.goal_week.toLocaleString("en-US")} خطوة{stepsThisWeek != null ? ` · المسجّل: ${stepsThisWeek.toLocaleString("en-US")}` : ""}</Body>
          <Field label="مجموع خطوات الأسبوع" value={steps} onChangeText={setSteps} keyboardType="number-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />
          <Button title="حفظ الخطوات" busy={busy === "log-steps"} disabled={parseNumber(steps, { max: 500000, integer: true }) === null}
            onPress={() => send("log-steps", { block: p.steps!.block, week: String(wk), total: String(parseNumber(steps, { max: 500000, integer: true })) })} />
        </Card>
      )}

      {records.length > 0 && (
        <Card>
          <Title>أرقامك القياسية (برامج المدربة)</Title>
          {records.slice(0, 15).map((r) => (
            <View key={r.exercise_id} style={[s.pr, { borderColor: t.line }]}>
              <Text style={{ color: t.text, fontSize: 15, flex: 1, textAlign: "left" }}>{r.status === "new" ? "🏆 " : ""}{r.name}</Text>
              <Text style={{ color: t.muted, fontSize: 14, writingDirection: "ltr" }}>{formatKg(r.best)} kg · 1RM {formatKg(r.oneRm)}</Text>
            </View>
          ))}
        </Card>
      )}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  grid: { flexDirection: "row", flexWrap: "wrap", gap: 10, justifyContent: "space-between" },
  pr: { flexDirection: "row", alignItems: "center", gap: 8, borderTopWidth: StyleSheet.hairlineWidth, paddingTop: 6 },
});
