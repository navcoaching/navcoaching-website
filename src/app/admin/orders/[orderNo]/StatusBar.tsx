"use client";
import { useState } from "react";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { transitionAction } from "@/app/actions/admin";

type Step = { to: string; label: string; needsBank?: boolean; needsNote?: boolean; free?: boolean };
const addDays = (ymd: string, n: number) => new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

/** شريط ثابت لتغيير حالة الطلب: قائمة بالانتقالات المسموحة فقط، والحقول تظهر حسب الاختيار */
export default function StatusBar({ orderNo, current, steps, amount, category = "follow", today = "", preferredStart = null }: {
  orderNo: string; current: string; steps: Step[]; amount: string; category?: string; today?: string; preferredStart?: string | null }) {
  const [to, setTo] = useState("");
  const start0 = preferredStart && preferredStart > today ? preferredStart : today;
  const [fs, setFs] = useState(start0), [fe, setFe] = useState("");
  const step = steps.find((s) => s.to === to);
  const { state, onSubmit, pending } = useFormAction(transitionAction, () =>
    step?.to === "cancelled" ? window.confirm("تأكيد إلغاء الطلب؟")
    : step?.free ? window.confirm(category === "follow" ? `قبول الطلب مجاناً وتفعيله من ${fs} إلى ${fe}؟` : "قبول الطلب مجاناً بدون دفع؟")
    : true);
  return (
    <form className="status-bar" onSubmit={onSubmit} data-testid="status-bar" aria-label="حالة الطلب">
      <input type="hidden" name="order_no" value={orderNo} />
      <div className="status-bar-row">
        <span className="small">الحالة: <b>{current}</b></span>
        {steps.length === 0 ? <span className="small muted">لا تغيير متاح لهذه الحالة.</span> : (
          <>
            <label htmlFor="sb-to" className="sr-only">تغيير الحالة إلى</label>
            <select id="sb-to" name="to" value={to} onChange={(e) => setTo(e.target.value)} required>
              <option value="" disabled>تغيير الحالة إلى…</option>
              {steps.map((s) => <option key={s.to} value={s.to}>{s.label}</option>)}
            </select>
            {step && !step.needsNote && (
              <input name="note" type="text" maxLength={500} placeholder="ملاحظة للعميل تُرسل له (اختياري)" aria-label="ملاحظة تظهر للعميل وتُرسل له بالإيميل وواتساب (اختياري)" />
            )}
            <Submit pending={pending} pendingText="جارٍ…" className={`btn btn-sm ${step?.to === "cancelled" ? "btn-danger" : ""}`} disabled={!step || pending}>تحديث</Submit>
          </>
        )}
      </div>
      {step?.needsNote && (
        <input name="note" type="text" maxLength={500} required placeholder="السبب (يُرسل للعميل) *" aria-label="السبب (يظهر للعميل ويُرسل له بالإيميل وواتساب)" className="status-bar-wide" />
      )}
      {step?.free && category === "follow" && (
        <div className="status-bar-free" data-testid="free-dates">
          <label>من <input name="free_start" type="date" value={fs} min={today} onChange={(e) => setFs(e.target.value)} required dir="ltr" /></label>
          <label>إلى (آخر يوم) <input name="free_end" type="date" value={fe} min={fs || today} onChange={(e) => setFe(e.target.value)} required dir="ltr" /></label>
          <span className="row" style={{ gap: 6, flexWrap: "wrap" }}>
            {[4, 8, 12].map((w) => (
              <button key={w} type="button" className="btn btn-ghost btn-sm" onClick={() => setFe(addDays(fs || today, w * 7 - 1))}>{w} أسابيع</button>
            ))}
          </span>
          <span className="small muted">الاشتراك المجاني يشتغل بس في هذي المدة، وينتهي تلقائياً بعد آخر يوم.</span>
        </div>
      )}
      {step?.needsBank && (
        <label className="check small"><input type="checkbox" name="bank_confirmed" required /><span>تأكدت من وصول المبلغ ({amount}) في كشف حساب المؤسسة ومطابقته لرقم الطلب.</span></label>
      )}
      <FormMessage state={state} />
    </form>
  );
}
