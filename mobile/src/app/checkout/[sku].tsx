import { randomUUID } from "expo-crypto";
import * as Haptics from "expo-haptics";
import { router, Stack, useLocalSearchParams } from "expo-router";
import { useEffect, useRef, useState, type ComponentProps, type ReactNode } from "react";
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { Body, Button, Card, Chip, ErrorText, Field, Title } from "@/components/ui";
import { apiAction } from "@/lib/api";
import {
  atHome, customField, healthYes, isFemale, needsCalories, SENSITIVE, STEP_TITLES, stepOf, str, toFields, validateStep,
  type Answers, type CheckoutData, type CustomQ,
} from "@/lib/checkout";
import { riyals } from "@/lib/content";
import { useApi } from "@/lib/use-api";
import { useTracker } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

const DRAFT_KEY = "checkout_draft";
const dayFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-latn", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
const addDays = (d: string, n: number) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

// طلب الباقة بالاستبيان من داخل التطبيق: نفس أسئلة الموقع (ونصوص لوحة الإدارة) في 5 خطوات، ثم صفحة الطلب بالمبلغ وبيانات التحويل.
export default function Checkout() {
  const { sku } = useLocalSearchParams<{ sku: string }>();
  const { data: d, error } = useApi<CheckoutData>(`/checkout?sku=${encodeURIComponent(sku)}`);
  const tracker = useTracker();
  const t = useTheme();
  const scroll = useRef<ScrollView>(null);
  const [a, setA] = useState<Answers | null>(null);
  const [step, setStep] = useState(1);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // المسودة (بدون البيانات الصحية والقياسات) ومفتاح منع التكرار: مرة واحدة لكل طلب
  useEffect(() => {
    if (!d || a) return;
    tracker.getSetting(DRAFT_KEY).then((raw) => {
      let draft: Answers = {};
      try { draft = raw ? JSON.parse(raw) : {}; } catch { /* مسودة تالفة */ }
      if (!draft.idempotency_key) draft.idempotency_key = randomUUID();
      if (!draft.name && d.defaultName) draft.name = d.defaultName;
      setA({ cc: "+966", start_mode: "asap", ...draft, sku: d.sku });
    });
  }, [d]);

  if (error === "login") {
    return (
      <View style={s.page}>
        <Card>
          <Title>سجّل دخولك أولاً</Title>
          <Body muted>الطلب يُحفظ في حسابك، ومنه تتابع الدفع والبرنامج.</Body>
          <Button title="تسجيل الدخول" onPress={() => router.push("/login")} />
        </Card>
      </View>
    );
  }
  if (error) return <View style={s.page}><ErrorText>{error}</ErrorText></View>;
  if (!d || !a) return null;

  const set = (k: string, v: string | string[]) => {
    setA((cur) => ({ ...cur!, [k]: v }));
    if (errors[k]) setErrors(({ [k]: _, ...rest }) => rest);
  };
  const saveDraft = (x: Answers) =>
    tracker.setSetting(DRAFT_KEY, JSON.stringify(Object.fromEntries(Object.entries(x).filter(([k]) => !SENSITIVE.has(k))))).catch(() => {});
  const go = (n: number) => { setStep(n); saveDraft(a); scroll.current?.scrollTo({ y: 0, animated: false }); };

  function next() {
    const e = validateStep(step, a!, d!);
    setErrors(e);
    if (Object.keys(e).length === 0) go(step + 1);
  }

  async function submit() {
    const e = validateStep(5, a!, d!);
    setErrors(e);
    if (Object.keys(e).length) return;
    const fd = new FormData();
    for (const [k, v] of toFields(a!)) fd.append(k, v);
    setBusy(true); setFormError(null);
    const r = await apiAction("create-order", fd);
    setBusy(false);
    if (r.fieldErrors) {
      setErrors(r.fieldErrors);
      const first = Math.min(...Object.keys(r.fieldErrors).map((k) => stepOf(k, d!)));
      setFormError(r.error ?? "راجع الحقول المحددة.");
      return go(first);
    }
    if (r.error || !r.message) return setFormError(r.error ?? "تعذّر الإرسال. حاول مرة ثانية.");
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    await tracker.setSetting(DRAFT_KEY, "{}").catch(() => {});
    Alert.alert("وصل طلبك ✓", `رقم طلبك ${r.message}. حوّل المبلغ وارفع صورة الإيصال من صفحة الطلب. نتواصل معك خلال ${d!.responseTime}.`);
    router.replace(`/order/${r.message}`);
  }

  const q = (k: string) => d.questions[k] ?? { label: k, hint: "", hidden: false };
  const show = (k: string) => !q(k).hidden;
  const opt = (k: string) => d.opt[k] ?? [];
  const extra = (n: number) => d.custom.filter((c) => c.step === n).map((c) => <Custom key={c.id} q={c} a={a} set={set} err={errors[customField(c.id)]} />);
  const offer = d.offers.find((o) => o.sku === str(a, "sku"));
  const age = Number(str(a, "age"));
  const field = (k: string, extraProps: Partial<ComponentProps<typeof Field>> = {}) => (
    <Q hint={q(k).hint} err={errors[k]}>
      <Field label={q(k).label} value={str(a, k)} onChangeText={(v) => set(k, v)} {...extraProps} />
    </Q>
  );

  return (
    <ScrollView ref={scroll} contentContainerStyle={s.page} keyboardShouldPersistTaps="handled">
      <Stack.Screen options={{ title: "استبيان المتدرب" }} />
      <View style={{ flexDirection: "row", gap: 6 }}>
        {[1, 2, 3, 4, 5].map((i) => <View key={i} style={[s.bar, { backgroundColor: t.navy, opacity: i <= step ? 1 : 0.25 }]} />)}
      </View>
      <Body muted>الخطوة {step} من 5 — {STEP_TITLES[step - 1]}</Body>

      {step === 1 && (
        <Card>
          <Pick label="الباقة والمدة" required err={errors.sku} opts={d.offers.map((o) => o.sku)} value={str(a, "sku")} onPick={(v) => set("sku", v)}
            name={(v) => { const o = d.offers.find((x) => x.sku === v)!; return `${o.product} — ${o.label} · ${riyals(o.price_halalas)}`; }} column />
          {offer && <Body muted>السعر {riyals(offer.price_halalas)}، تدفعه بتحويل بنكي بعد إرسال الاستبيان.</Body>}
          {field("name", { maxLength: 80, autoComplete: "name" })}
          <Pick label="رمز الدولة" opts={opt("cc")} value={str(a, "cc")} onPick={(v) => set("cc", v)} />
          {field("phone", { keyboardType: "phone-pad", maxLength: 20, style: { writingDirection: "ltr", textAlign: "left" } })}
          <Body muted>الرقم اللي تستخدمه في واتساب — نتواصل معك عليه.</Body>
          <Pick label={q("gender").label} hint={q("gender").hint} required err={errors.gender} opts={opt("gender")} value={str(a, "gender")} onPick={(v) => set("gender", v)} />
          {field("age", { keyboardType: "number-pad", maxLength: 3 })}
          {age > 0 && age < 18 && <Check label="أؤكد أن ولي الأمر موافق على الاشتراك." value={str(a, "guardian_ok")} onChange={(v) => set("guardian_ok", v)} err={errors.guardian_ok} />}
          {show("city") && <Pick label={q("city").label} hint={q("city").hint} opts={opt("city")} value={str(a, "city")} onPick={(v) => set("city", v)} optional />}
          <Check label="أنا طالب/طالبة وأبي خصم 10% (يُطلب إثبات بسيط، ونؤكد لك المبلغ النهائي قبل التحويل)" value={str(a, "student") === "نعم" ? "on" : ""} onChange={(v) => set("student", v ? "نعم" : "")} />
          {extra(1)}
        </Card>
      )}

      {step === 2 && (
        <Card>
          {(["goal", "level", "place"] as const).map((k) => (
            <Pick key={k} label={q(k).label} hint={q(k).hint} required err={errors[k]} opts={opt(k)} value={str(a, k)} onPick={(v) => set(k, v)} />
          ))}
          {atHome(a) && <Multi label={q("equip").label} opts={opt("equip")} value={(a.equip as string[]) ?? []} onChange={(v) => set("equip", v)} />}
          {(["days", "duration"] as const).map((k) => (
            <Pick key={k} label={q(k).label} hint={q(k).hint} required err={errors[k]} opts={opt(k)} value={str(a, k)} onPick={(v) => set(k, v)} />
          ))}
          {extra(2)}
        </Card>
      )}

      {step === 3 && (
        <Card>
          <Body muted>هذه الأسئلة لسلامتك فقط، ولا تُحفظ على جهازك أثناء التعبئة، ولا يطّلع عليها إلا المدربة. اكتب الحد الأدنى الذي يساعدني أراعي حالتك.</Body>
          <Pick label={q("injury").label} hint={q("injury").hint} required err={errors.injury} opts={opt("yesno")} value={str(a, "injury")} onPick={(v) => set("injury", v)} />
          <Pick label={q("condition").label} hint={q("condition").hint} required err={errors.condition} opts={opt("yesno")} value={str(a, "condition")} onPick={(v) => set("condition", v)} />
          {isFemale(a) && <Pick label={q("pregnancy").label} opts={opt("pregnancy")} value={str(a, "pregnancy")} onPick={(v) => set("pregnancy", v)} optional />}
          {healthYes(a) && field("health_notes", { multiline: true, maxLength: 600, style: s.multi })}
          <Check label="أفهم أن البرنامج لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي عند وجود حالة صحية أو إصابة." value={str(a, "health_ack")} onChange={(v) => set("health_ack", v)} err={errors.health_ack} />
          {extra(3)}
        </Card>
      )}

      {step === 4 && (
        <Card>
          {field("weight", { keyboardType: "decimal-pad", maxLength: 5 })}
          {field("height", { keyboardType: "decimal-pad", maxLength: 5 })}
          {show("bodyfat") && <Pick label={q("bodyfat").label} opts={opt(str(a, "gender") === "ذكر" ? "bodyfat_male" : "bodyfat_female")} value={str(a, "bodyfat")} onPick={(v) => set("bodyfat", v)} optional />}
          <Pick label={q("steps").label} hint={q("steps").hint} opts={opt("steps")} value={str(a, "steps")} onPick={(v) => set("steps", v)} optional />
          {show("sleep") && <Pick label={q("sleep").label} opts={opt("sleep")} value={str(a, "sleep")} onPick={(v) => set("sleep", v)} optional />}
          {show("job") && <Pick label={q("job").label} opts={opt("job")} value={str(a, "job")} onPick={(v) => set("job", v)} optional />}
          <Pick label={q("calories").label} hint={q("calories").hint} required={needsCalories(a, d)} err={errors.calories} opts={opt("calories")} value={str(a, "calories")} onPick={(v) => set("calories", v)} optional={!needsCalories(a, d)} />
          {extra(4)}
        </Card>
      )}

      {step === 5 && (
        <Card>
          {field("expectations", { multiline: true, maxLength: 1000, style: s.multi })}
          <StartPick range={d.startRange} mode={str(a, "start_mode")} date={str(a, "start_date")} err={errors.start_date}
            onChange={(mode, date) => { set("start_mode", mode); set("start_date", date); }} />
          {show("challenge") && field("challenge", { multiline: true, maxLength: 600, style: s.multi })}
          {show("prev_coach") && <Pick label={q("prev_coach").label} opts={opt("yesno")} value={str(a, "prev_coach")} onPick={(v) => set("prev_coach", v)} optional />}
          {show("prev_coach") && str(a, "prev_coach") === "نعم" && field("prev_why", { maxLength: 300 })}
          {show("source") && <Pick label={q("source").label} opts={opt("source")} value={str(a, "source")} onPick={(v) => set("source", v)} optional />}
          <Pick label={q("media").label} hint="اختيارك لا يؤثر على قبولك أو خدمتك أو التجديد المجاني، وتقدر تغيّره لاحقاً." required err={errors.media} opts={opt("media")} value={str(a, "media")} onPick={(v) => set("media", v)} column />
          {show("notes") && field("notes", { multiline: true, maxLength: 800, style: s.multi })}
          {extra(5)}
          <Check label="أؤكد صحة البيانات وأوافق على الشروط وسياسة الخصوصية." value={str(a, "consent_terms")} onChange={(v) => set("consent_terms", v)} err={errors.consent_terms}
            link={{ title: "اقرأ الشروط والخصوصية", onPress: () => router.push("/policies") }} />
          <Check label="أوافق على التواصل معي عبر واتساب بخصوص طلبي." value={str(a, "consent_wa")} onChange={(v) => set("consent_wa", v)} err={errors.consent_wa} />
          {/* الخادم يطلب تأكيداً إذا كان الاسم في الطلب غير اسم صاحب الحساب (مثل الموقع) */}
          {(!!errors.for_me || str(a, "for_me") === "on") && (
            <Check label={`${errors.for_me ?? ""} الطلب لي أنا صاحب هذا الحساب.`.trim()} value={str(a, "for_me")} onChange={(v) => set("for_me", v)} />
          )}
          <Body muted>بعد الإرسال: يظهر لك رقم طلبك والمبلغ وبيانات التحويل. حوّل وارفع صورة الإيصال من صفحة الطلب، ويتأكد اشتراكك بعد التحقق من وصول المبلغ. نتواصل معك خلال {d.responseTime}.</Body>
        </Card>
      )}

      {formError && <ErrorText>{formError}</ErrorText>}
      {Object.keys(errors).length > 0 && !formError && <ErrorText>راجع الحقول المحددة.</ErrorText>}
      {step < 5 ? <Button title="التالي" onPress={next} /> : <Button title="أرسل الاستبيان وانتقل للدفع" busy={busy} onPress={submit} />}
      {step > 1 && <Button title="رجوع" variant="ghost" onPress={() => go(step - 1)} />}
      <Body muted>مسجّل الدخول بـ {d.email}</Body>
    </ScrollView>
  );
}

// مكوّنات ثابتة خارج الشاشة حتى لا يُعاد إنشاؤها مع كل تغيير
function Q({ children, hint, err }: { children: ReactNode; hint?: string; err?: string }) {
  const t = useTheme();
  return (
    <View style={{ gap: 6 }}>
      {children}
      {!!hint && <Text style={{ color: t.muted, fontSize: 13, textAlign: "left" }}>{hint}</Text>}
      {!!err && <Text style={{ color: t.err, fontSize: 14, textAlign: "left" }} accessibilityRole="alert">{err}</Text>}
    </View>
  );
}

function Label({ text, required }: { text: string; required?: boolean }) {
  const t = useTheme();
  return <Text style={{ color: t.text, fontSize: 15, fontWeight: "600", textAlign: "left" }}>{text}{required ? <Text style={{ color: t.err }}> *</Text> : null}</Text>;
}

/** اختيار واحد. optional: الضغط على المختار يلغيه */
function Pick({ label, hint, required, optional, err, opts, value, onPick, name, column }: {
  label: string; hint?: string; required?: boolean; optional?: boolean; err?: string; opts: string[]; value: string;
  onPick: (v: string) => void; name?: (v: string) => string; column?: boolean;
}) {
  return (
    <Q hint={hint} err={err}>
      <Label text={label} required={required} />
      <View style={column ? { gap: 8, alignItems: "flex-start" } : s.wrap} accessibilityRole="radiogroup">
        {opts.map((o) => <Chip key={o} label={name ? name(o) : o} active={value === o} onPress={() => onPick(optional && value === o ? "" : o)} />)}
      </View>
    </Q>
  );
}

function Multi({ label, opts, value, onChange }: { label: string; opts: string[]; value: string[]; onChange: (v: string[]) => void }) {
  return (
    <Q>
      <Label text={label} />
      <View style={s.wrap}>
        {opts.map((o) => <Chip key={o} label={o} active={value.includes(o)} onPress={() => onChange(value.includes(o) ? value.filter((x) => x !== o) : [...value, o])} />)}
      </View>
    </Q>
  );
}

function Check({ label, value, onChange, err, link }: { label: string; value: string; onChange: (v: string) => void; err?: string; link?: { title: string; onPress: () => void } }) {
  const t = useTheme();
  const on = value === "on";
  return (
    <Q err={err}>
      <Pressable onPress={() => onChange(on ? "" : "on")} accessibilityRole="checkbox" accessibilityState={{ checked: on }}
        style={{ flexDirection: "row", gap: 10, alignItems: "flex-start", minHeight: 44, paddingVertical: 4 }}>
        <Ionicons name={on ? "checkbox" : "square-outline"} size={24} color={on ? t.navy : t.muted} />
        <Text style={{ color: t.text, fontSize: 15, lineHeight: 22, flex: 1, textAlign: "left" }}>{label}</Text>
      </Pressable>
      {link && <Pressable onPress={link.onPress} accessibilityRole="link"><Text style={{ color: t.navy, fontSize: 14, textAlign: "left" }}>{link.title}</Text></Pressable>}
    </Q>
  );
}

function StartPick({ range, mode, date, err, onChange }: { range: { min: string; max: string }; mode: string; date: string; err?: string; onChange: (mode: string, date: string) => void }) {
  const days: string[] = [];
  for (let x = range.min; x <= range.max; x = addDays(x, 1)) days.push(x);
  return (
    <Q err={err} hint="تقدر تغيّره من صفحة الطلب قبل بداية الاشتراك.">
      <Label text="متى تبي تبدأ؟" />
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
        <Chip label="⚡ بأقرب وقت" active={mode !== "date"} onPress={() => onChange("asap", "")} />
        {days.map((x) => <Chip key={x} label={dayFmt.format(Date.parse(`${x}T00:00:00Z`))} active={mode === "date" && date === x} onPress={() => onChange("date", x)} />)}
      </ScrollView>
    </Q>
  );
}

function Custom({ q, a, set, err }: { q: CustomQ; a: Answers; set: (k: string, v: string) => void; err?: string }) {
  const name = customField(q.id);
  if (q.type === "choice" || q.type === "yesno") {
    return <Pick label={q.label} hint={q.hint} required={q.required} optional={!q.required} err={err} opts={q.type === "yesno" ? ["نعم", "لا"] : q.options} value={str(a, name)} onPick={(v) => set(name, v)} />;
  }
  return (
    <Q hint={q.hint} err={err}>
      <Field label={q.required ? `${q.label} *` : q.label} value={str(a, name)} onChangeText={(v) => set(name, v)}
        multiline={q.type === "long"} maxLength={q.type === "long" ? 1000 : 300} style={q.type === "long" ? s.multi : undefined} />
    </Q>
  );
}

const s = StyleSheet.create({
  page: { padding: 16, gap: 16, paddingBottom: 64 },
  bar: { flex: 1, height: 5, borderRadius: 3 },
  wrap: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  multi: { minHeight: 100, textAlignVertical: "top", paddingTop: 12 },
});
