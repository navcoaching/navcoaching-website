import ActionForm from "@/components/admin/ActionForm";
import { applyCalorieSuggestionAction, confirmAutoKcalAction, dismissCalorieSuggestionAction, saveCalorieProfileAction } from "@/app/actions/calories";
import { EB_GOALS, PAF_LEVELS } from "@/lib/calories";
import { basis, explain, targetKcal } from "@/lib/calorie-suggest";
import type { CalorieState } from "@/lib/calorie-data";

const n0 = (v: number) => Math.round(v).toLocaleString("en-US");
const METHODS = [["tenhaaf", "Ten Haaf (الطول والعمر والجنس)"], ["cunningham", "Cunningham (نسبة الدهون)"], ["tinsley", "Tinsley (بنية عضلية عالية)"]] as const;

/** السعرات المقترحة من آخر بيانات المتدرب + بيانات الحساب (للمدربة) */
export default function CalorieSuggest({ orderNo, st }: { orderNo: string; st: CalorieState }) {
  const s = st.suggestion, p = st.profile;
  const now = st.weight ? targetKcal(p, st.weight.kg) : null;
  return (
    <section className="card stack" data-testid="calorie-suggest" aria-labelledby="cs-h">
      <h2 id="cs-h" style={{ fontSize: 19 }}>السعرات المقترحة</h2>
      {st.pendingAuto && st.target?.kcal != null && st.weight ? (
        <div className="alert warn stack" style={{ ["--space" as string]: "8px", flexDirection: "column", alignItems: "stretch" }} data-testid="auto-kcal">
          <b><span className="status action" data-testid="auto-badge">⏳ بانتظار تأكيدك</span> حُسبت السعرات تلقائياً: <span className="num">{n0(st.target.kcal)}</span> سعرة</b>
          <ul className="small" style={{ margin: 0, paddingInlineStart: 18 }}>{basis(p, st.weight).map((b) => <li key={b}>{b}</li>)}</ul>
          <span className="small muted">المتدرب ما يشوف الرقم حتى تأكدينه. تأكدي أن البيانات صحيحة ثم اضغطي «أكدت الحسبة». لو فيها خطأ عدّليها من «بيانات الحساب» وتتحدث الحسبة، أو اكتبي الرقم بنفسك في «الأرقام الغذائية اليومية». البروتين والكارب والدهون ما تنحط تلقائياً.</span>
          <ActionForm action={confirmAutoKcalAction} submit="أكدت الحسبة" submitClass="btn btn-sm">
            <input type="hidden" name="order_no" value={orderNo} />
            <input type="hidden" name="kcal" value={st.target.kcal} />
          </ActionForm>
        </div>
      ) : s ? (
        <div className="alert info stack" style={{ ["--space" as string]: "8px", flexDirection: "column", alignItems: "stretch" }} data-testid="suggestion">
          <b>مقترح: <span className="num">{n0(s.kcal)}</span> سعرة{s.diff != null && <> بدل <span className="num">{n0(s.kcal - s.diff)}</span> ({s.diff > 0 ? "+" : ""}{n0(s.diff)})</>}</b>
          {s.carbs != null && <span className="small">بروتين {s.protein}غ · دهون {s.fat}غ (كما هي) · كارب <b className="num">{s.carbs}</b>غ</span>}
          {s.lowCarb && <span className="small err-text">تنبيه: الكارب يصير قليل جداً مع هذه السعرات. راجعي البروتين والدهون قبل الاعتماد.</span>}
          <span className="small muted">{explain(p, s)}</span>
          <div className="row" style={{ gap: 8 }}>
            <ActionForm action={applyCalorieSuggestionAction} submit="اعتماد" submitClass="btn btn-sm" confirm={`تغيير هدف المتدرب إلى ${n0(s.kcal)} سعرة؟`}>
              <input type="hidden" name="order_no" value={orderNo} />
            </ActionForm>
            <ActionForm action={dismissCalorieSuggestionAction} submit="تجاهل" submitClass="btn btn-ghost btn-sm">
              <input type="hidden" name="order_no" value={orderNo} />
            </ActionForm>
          </div>
        </div>
      ) : (
        <p className="small muted" style={{ margin: 0 }} data-testid="no-suggestion">
          {st.missing.length ? `ينقص للحساب: ${st.missing.join("، ")}. أكمليها من «بيانات الحساب».`
            : !st.weight ? "لا يوجد وزن مسجّل بعد."
            : `لا يوجد تغيير مقترح. حسب البيانات الحالية: ${now != null ? n0(now) : "—"} سعرة (${st.weight.kg} كغ).`}
        </p>
      )}
      <p className="small muted" style={{ margin: 0 }}>يُحسب بحاسبة الموقع (Henselmans) من متوسط وزن آخر 7 أيام وبيانات المتدرب، ويظهر الاقتراح عند فرق 50 سعرة أو أكثر. المتدرب لا يرى الرقم المقترح حتى تعتمديه.</p>
      <details className="card flat" open={!st.stored || st.missing.length > 0}>
        <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>بيانات الحساب {st.stored ? "" : "(مبدئية من الاستبيان)"}</summary>
        <ActionForm action={saveCalorieProfileAction} submit="حفظ البيانات" submitClass="btn btn-ghost btn-sm">
          <input type="hidden" name="order_no" value={orderNo} />
          <div className="grid g3">
            <div className="field"><label htmlFor="cp-method">المعادلة</label>
              <select id="cp-method" name="method" defaultValue={p.method}>{METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
            <div className="field"><label htmlFor="cp-sex">الجنس</label>
              <select id="cp-sex" name="sex" defaultValue={p.sex ?? ""}><option value="">—</option><option value="female">أنثى</option><option value="male">ذكر</option></select></div>
            <div className="field"><label htmlFor="cp-age">العمر</label><input id="cp-age" name="age" type="number" min={10} max={90} dir="ltr" defaultValue={p.age ?? ""} /></div>
            <div className="field"><label htmlFor="cp-height">الطول (سم)</label><input id="cp-height" name="height" type="number" step="0.1" min={120} max={230} dir="ltr" defaultValue={p.height_cm ?? ""} /></div>
            <div className="field"><label htmlFor="cp-bf">نسبة الدهون %</label><input id="cp-bf" name="body_fat" type="number" step="0.1" min={3} max={60} dir="ltr" defaultValue={p.body_fat ?? ""} /></div>
            <div className="field"><label htmlFor="cp-paf">النشاط خارج التمرين</label>
              <select id="cp-paf" name="paf" defaultValue={String(Number(p.paf).toFixed(1))}>{PAF_LEVELS.map((o) => <option key={o.v} value={o.v}>{o.l}</option>)}</select></div>
            <div className="field"><label htmlFor="cp-days">أيام التمرين</label><input id="cp-days" name="days" type="number" min={0} max={7} dir="ltr" defaultValue={p.training_days} /></div>
            <div className="field"><label htmlFor="cp-min">مدة الجلسة (دقيقة)</label><input id="cp-min" name="minutes" type="number" min={0} max={240} dir="ltr" defaultValue={p.minutes} /></div>
            <div className="field"><label htmlFor="cp-eb">الهدف</label>
              <select id="cp-eb" name="eb_factor" defaultValue={String(Number(p.eb_factor))}>{EB_GOALS.map((o) => <option key={o.v} value={String(Number(o.v))}>{o.l}</option>)}</select></div>
          </div>
        </ActionForm>
      </details>
    </section>
  );
}
