import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import { saveIntakeQuestionsAction } from "@/app/actions/admin";
import { BUILTIN_QUESTIONS, CUSTOM_TYPES, LIMITS, STEP_TITLES, parseConfig, type CustomQuestion } from "@/lib/intake-config";

export const metadata = { title: "أسئلة الاستبيان" };

/** أسئلة الاستبيان: تعديل النصوص، إخفاء الاختياري، وإضافة أسئلة جديدة. ما يُحفظ هنا يظهر في صفحة الاستبيان مباشرة */
export default async function IntakeQuestionsPage() {
  const coach = await requireCoach();
  const cfg = parseConfig(await withUser(coach.id, async (tx) => (await tx.query("SELECT value FROM site_settings WHERE key = 'intake_questions'")).rows[0]?.value));
  const blank: CustomQuestion = { id: "", step: 5, type: "text", label: "", hint: "", options: [], required: false, active: true };
  const rows = [...cfg.custom, ...Array.from({ length: Math.max(0, LIMITS.custom - cfg.custom.length) }, () => blank)].slice(0, cfg.custom.length + 3);

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 900 }}>
      <h1>أسئلة الاستبيان</h1>
      <p className="muted">هذي الأسئلة تظهر للعميل في صفحة الاستبيان (5 خطوات) قبل الدفع. اللي تحفظينه هنا يتحدث في الموقع مباشرة.</p>
      <div className="alert info small">
        <b>ملاحظات:</b> خيارات الأسئلة الأساسية (الهدف، الأيام، الوقت…) ثابتة لأن حساب السعرات والبرنامج مبنيان عليها، والموافقات والباقة ثابتة. تقدرين تغيّرين نص أي سؤال وتضيفين تلميحاً تحته.
        لإرجاع النص الأصلي اتركي الخانة فاضية أو اكتبي النص الأصلي. الطلبات القديمة تحتفظ بإجاباتها.
      </div>

      <ActionForm action={saveIntakeQuestionsAction} submit="حفظ الأسئلة" className="form">
        {STEP_TITLES.map((title, si) => (
          <section key={title} className="card stack" data-testid={`intake-step-${si + 1}`} style={{ ["--space" as string]: "12px" }}>
            <h2 style={{ fontSize: 18 }}>الخطوة {si + 1}: {title}</h2>
            {si === 0 && <p className="small muted" style={{ margin: 0 }}>الباقة ورمز الدولة والطالب وموافقة ولي الأمر ثابتة.</p>}
            {BUILTIN_QUESTIONS.filter((q) => q.step === si + 1).map((q) => (
              <div key={q.key} className="card flat stack" style={{ ["--space" as string]: "8px" }} data-testid={`q-${q.key}`}>
                <div className="field"><label htmlFor={`l_${q.key}`}>نص السؤال</label>
                  <input id={`l_${q.key}`} name={`l_${q.key}`} type="text" maxLength={LIMITS.label} defaultValue={cfg.labels[q.key]?.label ?? q.label} /></div>
                <div className="field"><label htmlFor={`h_${q.key}`}>تلميح تحت السؤال (اختياري)</label>
                  <input id={`h_${q.key}`} name={`h_${q.key}`} type="text" maxLength={LIMITS.hint} defaultValue={cfg.labels[q.key]?.hint ?? ""} /></div>
                {q.hideable && (
                  <label className="check small"><input type="checkbox" name={`x_${q.key}`} defaultChecked={cfg.labels[q.key]?.hidden === true} />
                    <span>إخفاء هذا السؤال من الاستبيان{q.key === "prev_coach" ? " (ويخفي سؤال «ليه ما استمريت معه» تبعه)" : ""}</span></label>
                )}
              </div>
            ))}
          </section>
        ))}

        <section className="card stack" data-testid="intake-custom" style={{ ["--space" as string]: "12px" }}>
          <h2 style={{ fontSize: 18 }}>أسئلة إضافية</h2>
          <p className="small muted" style={{ margin: 0 }}>تظهر في آخر الخطوة اللي تختارينها، وإجاباتها تنحفظ مع الطلب وتشوفينها في صفحة الطلب. لحذف سؤال امسحي نصه. الخيارات: خيار في كل سطر (خيارين على الأقل).</p>
          {rows.map((c, i) => (
            <div key={i} className="card flat stack" style={{ ["--space" as string]: "8px" }} data-testid="custom-row">
              <input type="hidden" name={`c${i}_id`} value={c.id} />
              <div className="field"><label htmlFor={`c${i}_label`}>{c.label ? `سؤال إضافي ${i + 1}` : "سؤال جديد"}</label>
                <input id={`c${i}_label`} name={`c${i}_label`} type="text" maxLength={LIMITS.label} defaultValue={c.label} placeholder="اكتبي نص السؤال" /></div>
              <div className="grid g3">
                <div className="field"><label htmlFor={`c${i}_type`}>نوع السؤال</label>
                  <select id={`c${i}_type`} name={`c${i}_type`} defaultValue={c.type}>{CUSTOM_TYPES.map((t) => <option key={t.v} value={t.v}>{t.l}</option>)}</select></div>
                <div className="field"><label htmlFor={`c${i}_step`}>تظهر في الخطوة</label>
                  <select id={`c${i}_step`} name={`c${i}_step`} defaultValue={String(c.step)}>{STEP_TITLES.map((t, k) => <option key={t} value={k + 1}>{k + 1} — {t}</option>)}</select></div>
                <div className="field"><label htmlFor={`c${i}_hint`}>تلميح (اختياري)</label><input id={`c${i}_hint`} name={`c${i}_hint`} type="text" maxLength={LIMITS.hint} defaultValue={c.hint} /></div>
              </div>
              <div className="field"><label htmlFor={`c${i}_options`}>الخيارات (للاختيار من قائمة فقط، خيار في كل سطر)</label>
                <textarea id={`c${i}_options`} name={`c${i}_options`} rows={3} defaultValue={c.options.join("\n")} /></div>
              <div className="row" style={{ gap: 16, flexWrap: "wrap" }}>
                <label className="check small"><input type="checkbox" name={`c${i}_req`} defaultChecked={c.required} /><span>مطلوب</span></label>
                <label className="check small"><input type="checkbox" name={`c${i}_active`} defaultChecked={c.label ? c.active : true} /><span>ظاهر في الاستبيان</span></label>
              </div>
            </div>
          ))}
        </section>
      </ActionForm>
    </div>
  );
}
