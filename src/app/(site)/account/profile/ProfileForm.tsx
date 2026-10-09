"use client";
import { useState } from "react";
import { saveProfileAction } from "@/app/actions/client";
import { AGE_MAX, AGE_MIN, OPT } from "@/lib/intake";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";

type V = Record<string, string | string[] | number | null | undefined>;

/** استبيان العضو (بدون طلب): كل الحقول المهمة في صفحة واحدة، تُحفظ وتُحدَّث متى شاء */
export default function ProfileForm({ initial }: { initial: V }) {
  const { state, onSubmit, pending } = useFormAction(saveProfileAction);
  const s = (k: string) => (initial[k] == null ? "" : String(initial[k]));
  const [gender, setGender] = useState(s("gender"));
  const [place, setPlace] = useState(s("place"));
  const fe = state.fieldErrors ?? {};
  const err = (k: string) => (fe[k] ? <span className="err-msg">{fe[k]}</span> : null);
  const select = (name: string, label: string, opts: readonly string[], required = false, onChange?: (v: string) => void) => (
    <div className="field"><label htmlFor={`pf-${name}`}>{label}{required && <> <span className="req">*</span></>}</label>
      <select id={`pf-${name}`} name={name} defaultValue={s(name)} required={required} onChange={(e) => onChange?.(e.target.value)}>
        <option value="">اختر</option>{opts.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>{err(name)}</div>
  );
  const bodyfat = gender === "ذكر" ? OPT.bodyfat_male : OPT.bodyfat_female;
  const equip = Array.isArray(initial.equip) ? initial.equip : [];
  return (
    <form onSubmit={onSubmit} className="form" data-testid="profile-form" noValidate={false}>
      <h2 style={{ fontSize: 18 }}>معلومات أساسية</h2>
      <div className="grid g2">
        {select("gender", "الجنس", OPT.gender, true, setGender)}
        <div className="field"><label htmlFor="pf-age">العمر <span className="req">*</span></label>
          <input id="pf-age" name="age" type="number" inputMode="numeric" min={AGE_MIN} max={AGE_MAX} required defaultValue={s("age")} />{err("age")}</div>
        <div className="field"><label htmlFor="pf-weight">الوزن (كغ) <span className="req">*</span></label>
          <input id="pf-weight" name="weight" type="number" inputMode="decimal" min={30} max={250} step="0.1" required defaultValue={s("weight")} />{err("weight")}</div>
        <div className="field"><label htmlFor="pf-height">الطول (سم) <span className="req">*</span></label>
          <input id="pf-height" name="height" type="number" inputMode="numeric" min={120} max={230} step="0.1" required defaultValue={s("height")} />{err("height")}</div>
        {select("city", "المدينة", OPT.city)}
        <div className="field"><label htmlFor="pf-bodyfat">نسبة الدهون (إن عرفتها)</label>
          <select id="pf-bodyfat" name="bodyfat" defaultValue={s("bodyfat")}><option value="">اختر</option>{bodyfat.map((o) => <option key={o} value={o}>{o}</option>)}</select></div>
      </div>

      <h2 style={{ fontSize: 18 }}>الهدف والتمرين</h2>
      <div className="grid g2">
        {select("goal", "الهدف", OPT.goal, true)}
        {select("level", "المستوى", OPT.level, true)}
        {select("place", "مكان التمرين", OPT.place, true, setPlace)}
        {select("days", "أيام التمرين في الأسبوع", OPT.days, true)}
        {select("duration", "الوقت المتاح للتمرين", OPT.duration, true)}
      </div>
      {["البيت", "كلاهما"].includes(place) && (
        <fieldset className="field"><legend>الأدوات المتوفرة في البيت</legend>
          <div className="choices">{OPT.equip.map((o) => <label className="choice" key={o}><input type="checkbox" name="equip" value={o} defaultChecked={equip.includes(o)} /><span>{o}</span></label>)}</div>
        </fieldset>
      )}

      <h2 style={{ fontSize: 18 }}>الصحة</h2>
      <div className="grid g2">
        {select("injury", "عندك إصابة حالية؟", OPT.yesno, true)}
        {select("condition", "عندك حالة صحية؟", OPT.yesno, true)}
        {gender !== "ذكر" && select("pregnancy", "حمل / بعد الولادة", OPT.pregnancy)}
      </div>
      <div className="field"><label htmlFor="pf-hn">ملاحظات صحية (اختياري)</label><textarea id="pf-hn" name="health_notes" maxLength={600} defaultValue={s("health_notes")} />
        <span className="hint">تُحفظ منفصلة وتصل المدربة فقط.</span></div>

      <h2 style={{ fontSize: 18 }}>نمط الحياة</h2>
      <div className="grid g2">
        {select("steps", "الخطوات اليومية", OPT.steps)}
        {select("sleep", "ساعات النوم", OPT.sleep)}
        {select("job", "طبيعة اليوم", OPT.job)}
        {select("calories", "خبرتك بحساب السعرات", OPT.calories)}
      </div>
      <div className="field"><label htmlFor="pf-ch">أكبر تحدي عندك (اختياري)</label><textarea id="pf-ch" name="challenge" maxLength={600} defaultValue={s("challenge")} /></div>
      <div className="field"><label htmlFor="pf-nt">إضافات (اختياري)</label><textarea id="pf-nt" name="notes" maxLength={800} defaultValue={s("notes")} /></div>
      <FormMessage state={state} />
      <Submit pending={pending} className="btn">حفظ الاستبيان</Submit>
    </form>
  );
}
