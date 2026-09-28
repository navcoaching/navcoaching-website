"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { createOrderAction } from "@/app/actions/client";
import { AGE_MAX, AGE_MIN, EXPECTATIONS_Q, NUTRITION_SKUS, OPT } from "@/lib/intake";
import { Submit, useFormAction } from "@/components/FormBits";
import StartPrefFields from "@/components/StartPrefFields";
import { validStartPref } from "@/lib/schedule";

type OfferOpt = { sku: string; label: string; group: string; price: string };
type Props = { sku: string; offers: OfferOpt[]; defaultName: string; responseTime: string };

const DRAFT_KEY = "nav_checkout_draft_v2";
// البيانات الصحية والقياسات لا تُحفظ على الجهاز أثناء التعبئة (كما في الموقع الحالي)
const SENSITIVE = new Set(["injury", "condition", "pregnancy", "health_notes", "health_ack", "weight", "height", "bodyfat"]);
const STEP_OF: Record<string, number> = {
  sku: 1, name: 1, cc: 1, phone: 1, gender: 1, age: 1, guardian_ok: 1, city: 1, student: 1,
  goal: 2, level: 2, place: 2, equip: 2, days: 2, duration: 2,
  injury: 3, condition: 3, pregnancy: 3, health_notes: 3, health_ack: 3,
  weight: 4, height: 4, bodyfat: 4, steps: 4, sleep: 4, job: 4, calories: 4,
  expectations: 5, challenge: 5, prev_coach: 5, prev_why: 5, source: 5, media: 5, notes: 5, start_mode: 5, start_date: 5, consent_terms: 5, consent_wa: 5,
};
const TITLES = ["الباقة والتواصل", "الهدف والتمرين", "الصحة والإصابات", "القياسات ونمط الحياة", "التوقعات والإرسال"];

type Draft = Record<string, string | string[]>;
const readDraft = (): Draft => { try { return JSON.parse(localStorage.getItem(DRAFT_KEY) ?? "{}"); } catch { return {}; } };

export default function CheckoutForm({ sku, offers, defaultName, responseTime }: Props) {
  const formRef = useRef<HTMLFormElement>(null);
  const topRef = useRef<HTMLDivElement>(null);
  const { state, onSubmit, pending } = useFormAction(createOrderAction, () => step === 5 && validateStep(5));
  const [step, setStep] = useState(1);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [v, setV] = useState<Draft>({});
  const [draft, setDraft] = useState<Draft | null>(null);

  // تحميل المسودة وإنشاء مفتاح منع التكرار مرة واحدة لكل طلب
  useEffect(() => {
    const d = readDraft();
    if (!d.idempotency_key) d.idempotency_key = crypto.randomUUID();
    d.sku = sku;
    if (!d.name && defaultName) d.name = defaultName;
    setDraft(d);
    setV(d);
  }, [sku, defaultName]);

  useEffect(() => {
    if (state.fieldErrors) {
      setErrors(state.fieldErrors);
      const first = Object.keys(state.fieldErrors).map((k) => STEP_OF[k] ?? 5).sort()[0];
      if (first) setStep(first);
    }
  }, [state]);

  useEffect(() => { topRef.current?.scrollIntoView({ block: "start" }); }, [step]);

  function snapshot() {
    const fd = new FormData(formRef.current!);
    const o: Draft = {};
    for (const k of new Set(fd.keys())) o[k] = k === "equip" ? fd.getAll(k).map(String) : String(fd.get(k));
    return o;
  }
  function onChange(e: React.FormEvent) {
    const o = snapshot();
    setV(o);
    const name = (e.target as HTMLInputElement).name;
    if (errors[name]) setErrors(({ [name]: _, ...rest }) => rest);
    const safe = Object.fromEntries(Object.entries(o).filter(([k]) => !SENSITIVE.has(k)));
    try { localStorage.setItem(DRAFT_KEY, JSON.stringify(safe)); } catch { /* التخزين غير متاح */ }
  }

  const val = (k: string) => (typeof v[k] === "string" ? (v[k] as string) : "");
  const nutrition = NUTRITION_SKUS.includes(val("sku") || sku);
  const isFemale = val("gender") === "أنثى";
  const atHome = ["البيت", "كلاهما"].includes(val("place"));
  const healthYes = val("injury") === "نعم" || val("condition") === "نعم" || ["حامل", "بعد الولادة"].includes(val("pregnancy"));
  const bodyfat = val("gender") === "ذكر" ? OPT.bodyfat_male : OPT.bodyfat_female;
  const offer = useMemo(() => offers.find((o) => o.sku === (val("sku") || sku)), [offers, v, sku]); // eslint-disable-line react-hooks/exhaustive-deps

  function validateStep(n: number) {
    const fs = formRef.current!.querySelector<HTMLFieldSetElement>(`fieldset[data-step="${n}"]`)!;
    const errs: Record<string, string> = {};
    for (const el of Array.from(fs.querySelectorAll<HTMLInputElement>("input,select,textarea"))) {
      if (!el.name || el.closest("[hidden]") || el.name === "website") continue;
      if (!el.checkValidity() && !errs[el.name]) errs[el.name] = el.dataset.err ?? "هذا الحقل مطلوب.";
    }
    setErrors(errs);
    const first = Object.keys(errs)[0];
    if (first) formRef.current!.querySelector<HTMLElement>(`[name="${first}"]`)?.focus();
    return !first;
  }

  if (!draft) return <p className="muted">جارٍ التحميل…</p>;
  const d = (k: string) => (typeof draft[k] === "string" ? (draft[k] as string) : "");
  const inv = (n: string) => invalidProps(n, errors);

  const ctx = { d, errors };
  return (
    <div ref={topRef} style={{ scrollMarginTop: 90 }}>
      <div className="progress" aria-hidden="true">{[1, 2, 3, 4, 5].map((i) => <span key={i} className={i <= step ? "on" : ""} />)}</div>
      <p className="small muted" aria-live="polite">الخطوة {step} من 5 — {TITLES[step - 1]}</p>

      <form ref={formRef} data-noflow onSubmit={onSubmit} onChange={onChange} className="form" noValidate style={{ marginTop: 16 }}>
        <input type="hidden" name="idempotency_key" value={String(draft.idempotency_key)} />
        <div className="hp" aria-hidden="true"><label>اترك هذا الحقل فارغاً<input name="website" tabIndex={-1} autoComplete="off" /></label></div>

        {/* 1 */}
        <fieldset data-step="1" hidden={step !== 1} className="form">
          <div className="field">
            <label htmlFor="sku">الباقة والمدة <span className="req">*</span></label>
            <select id="sku" name="sku" defaultValue={sku} required data-err="اختر الباقة">
              {Array.from(new Set(offers.map((o) => o.group))).map((g) => (
                <optgroup key={g} label={g}>{offers.filter((o) => o.group === g).map((o) => <option key={o.sku} value={o.sku}>{o.label} — {o.price}</option>)}</optgroup>
              ))}
            </select>
            {offer && <span className="hint">السعر: {offer.price}. تدفعه بتحويل بنكي بعد إرسال الاستبيان.</span>}
          </div>
          <div className="field">
            <label htmlFor="name">الاسم <span className="req">*</span></label>
            <input id="name" name="name" type="text" autoComplete="name" defaultValue={d("name")} required minLength={2} maxLength={80} data-err="اكتب اسمك (حرفين على الأقل)." {...inv("name")} />
            <ErrText n="name" errors={errors} />
          </div>
          <div className="field">
            <label htmlFor="phone">رقم واتساب <span className="req">*</span></label>
            <div className="phone-row" dir="ltr">
              <select name="cc" aria-label="رمز الدولة" defaultValue={d("cc") || "+966"}>{OPT.cc.map((c) => <option key={c}>{c}</option>)}</select>
              <input id="phone" name="phone" type="tel" inputMode="tel" autoComplete="tel-national" defaultValue={d("phone")} required
                pattern={val("cc") === "+966" || !val("cc") ? "0?5[0-9]{8}" : "[0-9]{6,14}"}
                data-err={val("cc") === "+966" || !val("cc") ? "الرقم السعودي يبدأ بـ 5 ويتكون من 9 أرقام، مثل 512345678." : "اكتب رقماً صحيحاً."} {...inv("phone")} />
            </div>
            <span className="hint">الرقم اللي تستخدمه في واتساب — نتواصل معك عليه.</span>
            <ErrText n="phone" errors={errors} />
          </div>
          <fieldset className="field"><legend>الجنس <span className="req">*</span></legend><Radios ctx={ctx} name="gender" opts={OPT.gender} required err="اختر الجنس — نحتاجه لتصميم البرنامج والمراجع المناسبة." /><ErrText n="gender" errors={errors} /></fieldset>
          <div className="field">
            <label htmlFor="age">العمر <span className="req">*</span></label>
            <input id="age" name="age" type="number" inputMode="numeric" min={AGE_MIN} max={AGE_MAX} step={1} required defaultValue={d("age")}
              data-err={`اكتب عمرك رقماً صحيحاً بين ${AGE_MIN} و ${AGE_MAX}.`} {...inv("age")} style={{ maxWidth: 160 }} />
            <ErrText n="age" errors={errors} />
          </div>
          <label className="check" hidden={!(Number(val("age")) > 0 && Number(val("age")) < 18)}>
            <input type="checkbox" name="guardian_ok" required={Number(val("age")) > 0 && Number(val("age")) < 18} data-err="للأعمار أقل من 18 نحتاج تأكيد موافقة ولي الأمر." {...inv("guardian_ok")} />
            <span>أؤكد أن ولي الأمر موافق على الاشتراك. <span className="req">*</span></span>
          </label>
          <ErrText n="guardian_ok" errors={errors} />
          <div className="field"><label htmlFor="city">المدينة (اختياري)</label><Select ctx={ctx} name="city" opts={OPT.city} /></div>
          <label className="check"><input type="checkbox" name="student" value="نعم" defaultChecked={d("student") === "نعم"} /><span>أنا طالب/طالبة وأبي خصم 10% (يُطلب إثبات بسيط، ونؤكد لك المبلغ النهائي قبل التحويل)</span></label>
        </fieldset>

        {/* 2 */}
        <fieldset data-step="2" hidden={step !== 2} className="form">
          <fieldset className="field"><legend>هدفك الرئيسي <span className="req">*</span></legend><Radios ctx={ctx} name="goal" opts={OPT.goal} required err="اختر هدفاً واحداً — الأقرب لك الآن." /><ErrText n="goal" errors={errors} /></fieldset>
          <fieldset className="field"><legend>مستواك <span className="req">*</span></legend><Radios ctx={ctx} name="level" opts={OPT.level} required err="اختر مستواك." /><ErrText n="level" errors={errors} /></fieldset>
          <fieldset className="field"><legend>مكان التمرين <span className="req">*</span></legend><Radios ctx={ctx} name="place" opts={OPT.place} required err="اختر مكان التمرين." /><ErrText n="place" errors={errors} /></fieldset>
          <fieldset className="field" hidden={!atHome}>
            <legend>الأدوات المتوفرة في البيت (اختر كل ما ينطبق)</legend>
            <div className="choices">
              {OPT.equip.map((o) => (
                <label className="choice" key={o}><input type="checkbox" name="equip" value={o} defaultChecked={Array.isArray(draft.equip) && draft.equip.includes(o)} /><span>{o}</span></label>
              ))}
            </div>
          </fieldset>
          <div className="field"><label htmlFor="days">أيام التمرين بالأسبوع <span className="req">*</span></label><Select ctx={ctx} name="days" opts={OPT.days} required err="اختر عدد الأيام." /><ErrText n="days" errors={errors} /></div>
          <div className="field"><label htmlFor="duration">وقت التمرين باليوم <span className="req">*</span></label><Select ctx={ctx} name="duration" opts={OPT.duration} required err="اختر الوقت المتاح." /><ErrText n="duration" errors={errors} /></div>
        </fieldset>

        {/* 3 */}
        <fieldset data-step="3" hidden={step !== 3} className="form">
          <p className="alert info">هذه الأسئلة لسلامتك فقط، ولا تُحفظ على جهازك أثناء التعبئة، ولا يطّلع عليها إلا المدربة. اكتب الحد الأدنى الذي يساعدني أراعي حالتك.</p>
          <fieldset className="field"><legend>هل عندك إصابة حالية أو ألم يحد من التمرين؟ <span className="req">*</span></legend><Radios ctx={ctx} name="injury" opts={OPT.yesno} required err="اختر نعم أو لا." /><ErrText n="injury" errors={errors} /></fieldset>
          <fieldset className="field"><legend>هل عندك حالة صحية أو تعليمات طبية قد تؤثر على التمرين؟ <span className="req">*</span></legend><Radios ctx={ctx} name="condition" opts={OPT.yesno} required err="اختر نعم أو لا." /><ErrText n="condition" errors={errors} /></fieldset>
          <fieldset className="field" hidden={!isFemale}><legend>هل أنتِ حامل أو في السنة الأولى بعد الولادة؟ (اختياري)</legend><Radios ctx={ctx} name="pregnancy" opts={OPT.pregnancy} /></fieldset>
          <div className="field" hidden={!healthYes}>
            <label htmlFor="health_notes">وضّح باختصار (مثال: ألم أسفل الظهر مع الانحناء)</label>
            <textarea id="health_notes" name="health_notes" maxLength={600} />
            <span className="hint">لا حاجة لإرسال تقارير طبية هنا.</span>
          </div>
          <label className="check">
            <input type="checkbox" name="health_ack" required data-err="نحتاج موافقتك على هذه النقطة للمتابعة." {...inv("health_ack")} />
            <span>أفهم أن البرنامج لا يغني عن استشارة الطبيب أو أخصائي العلاج الطبيعي عند وجود حالة صحية أو إصابة. <span className="req">*</span></span>
          </label>
          <ErrText n="health_ack" errors={errors} />
        </fieldset>

        {/* 4 */}
        <fieldset data-step="4" hidden={step !== 4} className="form">
          <div className="grid g2">
            <div className="field"><label htmlFor="weight">الوزن الحالي (كغ) <span className="req">*</span></label><input id="weight" name="weight" type="number" inputMode="decimal" min={30} max={250} step="0.1" required data-err="اكتب وزناً بين 30 و 250 كغ." {...inv("weight")} /><ErrText n="weight" errors={errors} /></div>
            <div className="field"><label htmlFor="height">الطول (سم) <span className="req">*</span></label><input id="height" name="height" type="number" inputMode="numeric" min={120} max={230} step="0.1" required data-err="اكتب طولاً بين 120 و 230 سم." {...inv("height")} /><ErrText n="height" errors={errors} /></div>
          </div>
          <div className="field"><label htmlFor="bodyfat">نسبة الدهون التقريبية (اختياري)</label>
            <select id="bodyfat" name="bodyfat" defaultValue=""><option value="">اختر</option>{bodyfat.map((o) => <option key={o}>{o}</option>)}</select>
          </div>
          <div className="field"><label htmlFor="steps">خطواتك اليومية</label><Select ctx={ctx} name="steps" opts={OPT.steps} /></div>
          <div className="field"><label htmlFor="sleep">ساعات النوم</label><Select ctx={ctx} name="sleep" opts={OPT.sleep} /></div>
          <div className="field"><label htmlFor="job">طبيعة يومك (اختياري)</label><Select ctx={ctx} name="job" opts={OPT.job} /></div>
          <div className="field">
            <label htmlFor="calories">خبرتك في حساب السعرات {nutrition && <span className="req">*</span>}</label>
            <Select ctx={ctx} name="calories" opts={OPT.calories} required={nutrition} err="اختر خبرتك — باقتك تشمل تغذية." />
            <ErrText n="calories" errors={errors} />
          </div>
        </fieldset>

        {/* 5 */}
        <fieldset data-step="5" hidden={step !== 5} className="form">
          <div className="field">
            <label htmlFor="expectations">{EXPECTATIONS_Q} <span className="req">*</span></label>
            <textarea id="expectations" name="expectations" required minLength={3} maxLength={1000} defaultValue={d("expectations")} data-err="هذا السؤال مطلوب." {...inv("expectations")} />
            <ErrText n="expectations" errors={errors} />
          </div>
          <StartPrefFields key={draft ? "draft" : "new"} idPrefix="co-start" error={errors.start_date}
            initial={draft?.start_mode === "date" && validStartPref(String(draft.start_date ?? "")) ? String(draft.start_date) : null} />
          <div className="field"><label htmlFor="challenge">وش أكبر تحدي تواجهه الآن؟ (اختياري)</label><textarea id="challenge" name="challenge" maxLength={600} defaultValue={d("challenge")} /></div>
          <fieldset className="field"><legend>تدربت مع مدرب قبل؟</legend><Radios ctx={ctx} name="prev_coach" opts={OPT.yesno} /></fieldset>
          <div className="field" hidden={val("prev_coach") !== "نعم"}><label htmlFor="prev_why">ليه ما استمريت معه؟ (اختياري)</label><input id="prev_why" name="prev_why" type="text" maxLength={300} defaultValue={d("prev_why")} /></div>
          <div className="field"><label htmlFor="source">من وين سمعت عني؟</label><Select ctx={ctx} name="source" opts={OPT.source} /></div>
          <div className="field">
            <label htmlFor="media">هل تسمح بعرض نتيجتك في السوشل ميديا؟ <span className="req">*</span></label>
            <Select ctx={ctx} name="media" opts={OPT.media} required err="اختر إجابة." />
            <span className="hint">اختيارك لا يؤثر على قبولك أو خدمتك أو التجديد المجاني، وتقدر تغيّره لاحقاً.</span>
            <ErrText n="media" errors={errors} />
          </div>
          <div className="field"><label htmlFor="notes">أي شي تبي تضيفه؟ (اختياري)</label><textarea id="notes" name="notes" maxLength={800} defaultValue={d("notes")} /></div>
          <label className="check">
            <input type="checkbox" name="consent_terms" required data-err="نحتاج موافقتك للإرسال." {...inv("consent_terms")} />
            <span>أؤكد صحة البيانات وأوافق على <Link href="/policies#terms" target="_blank">الشروط</Link> و<Link href="/policies#privacy" target="_blank">سياسة الخصوصية</Link>. <span className="req">*</span></span>
          </label>
          <ErrText n="consent_terms" errors={errors} />
          <label className="check">
            <input type="checkbox" name="consent_wa" required data-err="التواصل يتم على واتساب، فنحتاج موافقتك." {...inv("consent_wa")} />
            <span>أوافق على التواصل معي عبر واتساب بخصوص طلبي. <span className="req">*</span></span>
          </label>
          <ErrText n="consent_wa" errors={errors} />
          <div className="card flat">
            <p><b>بعد الإرسال:</b> يظهر لك رقم طلبك والمبلغ وبيانات التحويل في حسابك. حوّل وارفع صورة الإيصال من صفحة الطلب، ويتأكد اشتراكك بعد التحقق من وصول المبلغ. نتواصل معك خلال {responseTime}.</p>
          </div>
        </fieldset>

        {state.error && !state.fieldErrors && <p className="alert err" role="alert">{state.error}</p>}
        {state.fieldErrors && <p className="alert err" role="alert">{state.error}</p>}

        <div className="row" style={{ justifyContent: "space-between" }}>
          {step > 1 ? <button type="button" className="btn btn-ghost" onClick={() => setStep(step - 1)}>رجوع</button> : <span />}
          {step < 5 ? (
            <button type="button" className="btn" onClick={() => { if (validateStep(step)) setStep(step + 1); }}>التالي</button>
          ) : (
            <Submit className="btn btn-cyan" pending={pending} pendingText="جارٍ إرسال الطلب…">أرسل الاستبيان وانتقل للدفع</Submit>
          )}
        </div>
      </form>
    </div>
  );
}

// مكوّنات ثابتة خارج النموذج حتى لا يُعاد إنشاؤها مع كل تغيير (وتضيع الاختيارات)
type Ctx = { d: (k: string) => string; errors: Record<string, string> };
const invalidProps = (n: string, errors: Record<string, string>) => ({ "aria-invalid": errors[n] ? true : undefined, "aria-describedby": errors[n] ? `e-${n}` : undefined });
function ErrText({ n, errors }: { n: string; errors: Record<string, string> }) {
  return errors[n] ? <span className="err-msg" id={`e-${n}`}>{errors[n]}</span> : null;
}
function Radios({ ctx, name, opts, required, err }: { ctx: Ctx; name: string; opts: readonly string[]; required?: boolean; err?: string }) {
  return (
    <div className="choices" role="radiogroup">
      {opts.map((o, i) => (
        <label className="choice" key={o}>
          <input type="radio" name={name} value={o} defaultChecked={ctx.d(name) === o} required={required && i === 0} data-err={err} {...invalidProps(name, ctx.errors)} />
          <span>{o}</span>
        </label>
      ))}
    </div>
  );
}
function Select({ ctx, name, opts, required, err, id }: { ctx: Ctx; name: string; opts: readonly string[]; required?: boolean; err?: string; id?: string }) {
  return (
    <select id={id ?? name} name={name} defaultValue={ctx.d(name)} required={required} data-err={err} {...invalidProps(name, ctx.errors)}>
      <option value="">اختر</option>
      {opts.map((o) => <option key={o}>{o}</option>)}
    </select>
  );
}
