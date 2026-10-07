import { useState } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { Body, Button, Card, Chip, ErrorText, Field, Title } from "@/components/ui";
import { openSite } from "@/lib/links";
import {
  EB_GOALS, MACRO_DEFAULTS, PAF_LEVELS, PROTEIN_LEVELS, calculateEnergyBalance, calculateIntake, macrosFor, proteinPerKg,
  validate, validateIntake, validateMacroSettings, type BmrMethod, type EnergyInput, type EnergyResult, type IntakeInput, type IntakeResult,
} from "@/shared/calories";
import { useTheme } from "@/lib/theme";

// حاسبة السعرات (نفس معادلات الموقع حرفياً من src/shared/calories.ts) — تعمل بدون إنترنت
const n = (v: string) => (v.trim() === "" ? NaN : Number(v.replace(",", ".").replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))));
const fmt = (v: number) => Math.round(v).toLocaleString("en-US");
const signed = (v: number) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${fmt(Math.abs(v))}`;
const DAYS = [0, 1, 2, 3, 4, 5, 6, 7];
const METHODS: { v: BmrMethod; t: string }[] = [
  { v: "cunningham", t: "أعرف نسبة الدهون" },
  { v: "tenhaaf", t: "ما أعرف نسبة الدهون" },
  { v: "tinsley", t: "رياضي بنية عضلية عالية" },
];

export default function Calculator() {
  const [tab, setTab] = useState<"intake" | "balance">("intake");
  return (
    <ScrollView contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <View style={{ flexDirection: "row", gap: 8 }}>
        <Chip label="سعراتي اليومية" active={tab === "intake"} onPress={() => setTab("intake")} />
        <Chip label="توازن الطاقة" active={tab === "balance"} onPress={() => setTab("balance")} />
      </View>
      {tab === "intake" ? <Intake /> : <Balance />}
      <Card>
        <Body>تبي خطة تدريب وتغذية مبنية على أرقامك مع متابعة أسبوعية؟</Body>
        <Button title="شوف البرامج" variant="ghost" onPress={() => openSite("/programs")} />
      </Card>
    </ScrollView>
  );
}

function Stat({ label, value, unit }: { label: string; value: string; unit: string }) {
  const t = useTheme();
  return (
    <View style={[s.stat, { borderColor: t.line, backgroundColor: t.paper }]}>
      <Text style={{ color: t.muted, fontSize: 13, textAlign: "center" }}>{label}</Text>
      <Text style={{ color: t.heading, fontSize: 22, fontWeight: "800", textAlign: "center", writingDirection: "ltr" }}>{value}</Text>
      <Text style={{ color: t.muted, fontSize: 12, textAlign: "center" }}>{unit}</Text>
    </View>
  );
}

function Intake() {
  const t = useTheme();
  const [method, setMethod] = useState<BmrMethod>("cunningham");
  const [f, setF] = useState({ weight: "", bodyFat: "", heightCm: "", age: "", minutes: "60" });
  const [sex, setSex] = useState<"male" | "female" | null>(null);
  const [paf, setPaf] = useState("1.0");
  const [days, setDays] = useState(4);
  const [goal, setGoal] = useState("0.8");
  const [protein, setProtein] = useState<string>(MACRO_DEFAULTS.proteinLevel);
  const [fat, setFat] = useState(String(MACRO_DEFAULTS.fatPerKg));
  const [errors, setErrors] = useState<Record<string, string | undefined>>({});
  const [result, setResult] = useState<IntakeResult | null>(null);

  function calc() {
    const input = { method, weight: n(f.weight), bodyFat: n(f.bodyFat), heightCm: n(f.heightCm), age: n(f.age), sex, paf: n(paf), minutes: n(f.minutes), trainingDays: days, ebFactor: n(goal) };
    const errs = validateIntake(input);
    setErrors(errs);
    setResult(Object.keys(errs).length ? null : calculateIntake(input as IntakeInput));
  }
  const field = (k: keyof typeof f, label: string) => (
    <View style={{ flex: 1, minWidth: "45%" }}>
      <Field label={label} value={f[k]} onChangeText={(v) => setF({ ...f, [k]: v })} keyboardType="decimal-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />
      {errors[k] && <Text style={{ color: t.err, fontSize: 13, textAlign: "left" }}>{errors[k]}</Text>}
    </View>
  );
  const ms = { proteinPerKg: proteinPerKg(protein), fatPerKg: n(fat) };
  const msErr = validateMacroSettings(ms);
  const weight = n(f.weight);
  const macro = (label: string, kcal: number) => {
    const m = macrosFor(kcal, weight, ms);
    return <Body key={label}>{label} ({fmt(kcal)}): بروتين {m.protein}غ · كارب {m.carbs}غ · دهون {m.fat}غ</Body>;
  };

  return (
    <>
      <Card>
        <Title>طريقة الحساب</Title>
        <View style={s.wrap}>{METHODS.map((m) => <Chip key={m.v} label={m.t} active={method === m.v} onPress={() => setMethod(m.v)} />)}</View>
        <View style={s.wrap}>
          {field("weight", "الوزن (كغ)")}
          {method === "cunningham" && field("bodyFat", "نسبة الدهون (%)")}
          {method === "tenhaaf" && field("heightCm", "الطول (سم)")}
          {method === "tenhaaf" && field("age", "العمر")}
        </View>
        {method === "tenhaaf" && (
          <View style={s.wrap}>
            <Chip label="ذكر" active={sex === "male"} onPress={() => setSex("male")} />
            <Chip label="أنثى" active={sex === "female"} onPress={() => setSex("female")} />
            {errors.sex && <Text style={{ color: t.err }}>{errors.sex}</Text>}
          </View>
        )}
        <Text style={[s.label, { color: t.text }]}>نشاطك اليومي خارج التمرين</Text>
        <View style={s.wrap}>{PAF_LEVELS.map((o) => <Chip key={o.v} label={o.l} active={paf === o.v} onPress={() => setPaf(o.v)} />)}</View>
        <Text style={[s.label, { color: t.text }]}>أيام تمرين المقاومة في الأسبوع</Text>
        <View style={s.wrap}>{DAYS.map((d) => <Chip key={d} label={String(d)} active={days === d} onPress={() => setDays(d)} />)}</View>
        {days > 0 && <View style={s.wrap}>{field("minutes", "مدة الجلسة (دقيقة)")}</View>}
        <Text style={[s.label, { color: t.text }]}>هدفك</Text>
        <View style={s.wrap}>{EB_GOALS.map((o) => <Chip key={o.v} label={o.l} active={goal === o.v} onPress={() => setGoal(o.v)} />)}</View>
        <Button title="احسب السعرات" onPress={calc} />
      </Card>
      {result && (
        <Card>
          <Title>النتيجة</Title>
          <View style={s.wrap}>
            <Stat label="متوسط سعراتك لهدفك" value={fmt(result.target)} unit="سعرة يومياً" />
            {days > 0 && <Stat label="يوم التمرين" value={fmt(result.trainingDayTarget)} unit="سعرة" />}
            {days < 7 && <Stat label="يوم الراحة" value={fmt(result.restDayTarget)} unit="سعرة" />}
            <Stat label="سعرات المحافظة" value={fmt(result.maintenance)} unit="سعرة" />
            <Stat label="الأيض الأساسي" value={fmt(result.bmr)} unit="سعرة" />
          </View>
          <Text style={[s.label, { color: t.text }]}>الماكروز (تقدير مبدئي)</Text>
          <View style={s.wrap}>{PROTEIN_LEVELS.map((o) => <Chip key={o.v} label={o.l} active={protein === o.v} onPress={() => setProtein(o.v)} />)}</View>
          <Field label="الدهون (غ لكل كغ)" value={fat} onChangeText={setFat} keyboardType="decimal-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />
          {msErr.fatPerKg ? <ErrorText>{msErr.fatPerKg}</ErrorText> : (
            <>
              {macro("المتوسط", result.target)}
              {days > 0 && macro("يوم التمرين", result.trainingDayTarget)}
              {days < 7 && macro("يوم الراحة", result.restDayTarget)}
            </>
          )}
          <Body muted>نقطة بداية تقريبية: راقب وزنك وقياساتك أسبوعين إلى ثلاثة، وعدّل حسب النتيجة. المعادلات من حاسبة Menno Henselmans.</Body>
        </Card>
      )}
    </>
  );
}

function Balance() {
  const t = useTheme();
  const [r, setR] = useState({ leanDir: "up" as "up" | "down", lean: "", fatDir: "down" as "up" | "down", fat: "", startDate: "", endDate: "", trainingKcal: "", restKcal: "" });
  const [days, setDays] = useState(4);
  const [errors, setErrors] = useState<Record<string, string | undefined>>({});
  const [result, setResult] = useState<EnergyResult | null>(null);
  function calc() {
    const lean = n(r.lean), fat = n(r.fat);
    const input = {
      leanChange: Number.isNaN(lean) ? NaN : (r.leanDir === "down" ? -1 : 1) * Math.abs(lean),
      fatChange: Number.isNaN(fat) ? NaN : (r.fatDir === "down" ? -1 : 1) * Math.abs(fat),
      startDate: r.startDate.trim(), endDate: r.endDate.trim(), trainingKcal: n(r.trainingKcal), trainingDays: days, restKcal: n(r.restKcal),
    };
    const errs = validate(input);
    setErrors(errs);
    setResult(Object.keys(errs).length ? null : calculateEnergyBalance(input as EnergyInput));
  }
  const err = (k: string) => errors[k] ? <Text style={{ color: t.err, fontSize: 13, textAlign: "left" }}>{errors[k]}</Text> : null;
  const change = (dir: "leanDir" | "fatDir", k: "lean" | "fat", ek: string, label: string) => (
    <View style={{ gap: 6 }}>
      <Text style={[s.label, { color: t.text }]}>{label}</Text>
      <View style={[s.wrap, { alignItems: "center" }]}>
        <Chip label="زاد" active={r[dir] === "up"} onPress={() => setR({ ...r, [dir]: "up" })} />
        <Chip label="نقص" active={r[dir] === "down"} onPress={() => setR({ ...r, [dir]: "down" })} />
        <View style={{ flex: 1 }}><Field label="كغ" value={r[k]} onChangeText={(v) => setR({ ...r, [k]: v })} keyboardType="decimal-pad" style={{ textAlign: "center", writingDirection: "ltr" }} /></View>
      </View>
      {err(ek)}
    </View>
  );
  const deficit = result ? result.dailyBalance < 0 : false;
  return (
    <>
      <Card>
        <Title>التغيّر في جسمك</Title>
        <Body muted>قارن بين قياسين (مثل فحصي InBody) بينهما 4 أسابيع أو أكثر، واكتب الفرق.</Body>
        {change("leanDir", "lean", "leanChange", "الكتلة الخالية من الدهون")}
        {change("fatDir", "fat", "fatChange", "كتلة الدهون (بالكيلو، مو النسبة)")}
        <View style={s.wrap}>
          <View style={{ flex: 1 }}><Field label="تاريخ القياس الأول" value={r.startDate} onChangeText={(v) => setR({ ...r, startDate: v })} placeholder="2026-09-01" style={{ textAlign: "center", writingDirection: "ltr" }} />{err("startDate")}</View>
          <View style={{ flex: 1 }}><Field label="تاريخ القياس الثاني" value={r.endDate} onChangeText={(v) => setR({ ...r, endDate: v })} placeholder="2026-10-01" style={{ textAlign: "center", writingDirection: "ltr" }} />{err("endDate")}</View>
        </View>
        <Title>أكلك خلال نفس الفترة</Title>
        <View style={s.wrap}>
          <View style={{ flex: 1 }}><Field label="سعرات يوم التمرين" value={r.trainingKcal} onChangeText={(v) => setR({ ...r, trainingKcal: v })} keyboardType="number-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />{err("trainingKcal")}</View>
          <View style={{ flex: 1 }}><Field label="سعرات يوم الراحة" value={r.restKcal} onChangeText={(v) => setR({ ...r, restKcal: v })} keyboardType="number-pad" style={{ textAlign: "center", writingDirection: "ltr" }} />{err("restKcal")}</View>
        </View>
        <Text style={[s.label, { color: t.text }]}>أيام التمرين في الأسبوع</Text>
        <View style={s.wrap}>{DAYS.map((d) => <Chip key={d} label={String(d)} active={days === d} onPress={() => setDays(d)} />)}</View>
        <Button title="احسب توازن الطاقة" onPress={calc} />
      </Card>
      {result && (
        <Card>
          <Title>النتيجة</Title>
          <Stat label="توازن الطاقة اليومي" value={signed(result.dailyBalance)} unit={`سعرة يومياً · ${deficit ? "عجز" : result.dailyBalance > 0 ? "فائض" : "توازن"} ${Math.round(Math.abs(result.dailyBalancePct) * 100)}٪`} />
          <View style={s.wrap}>
            <Stat label="سعرات المحافظة الفعلية" value={fmt(result.maintenance)} unit="سعرة يومياً" />
            <Stat label="متوسط أكلك" value={fmt(result.avgIntake)} unit="سعرة" />
            <Stat label="صافي الفترة" value={signed(result.netKcal)} unit="سعرة" />
            <Stat label="مدة الفترة" value={String(result.days)} unit="يوم" />
          </View>
          {result.warnings.map((w) => <ErrorText key={w}>{w}</ErrorText>)}
        </Card>
      )}
    </>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 48 },
  wrap: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  label: { fontSize: 15, fontWeight: "600", textAlign: "left" },
  stat: { flexGrow: 1, minWidth: "45%", borderWidth: 1, borderRadius: 12, padding: 10, gap: 2 },
});
