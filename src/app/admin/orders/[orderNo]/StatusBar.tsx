"use client";
import { useState } from "react";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { transitionAction } from "@/app/actions/admin";

type Step = { to: string; label: string; needsBank?: boolean; needsNote?: boolean };

/** شريط ثابت لتغيير حالة الطلب: قائمة بالانتقالات المسموحة فقط، والحقول تظهر حسب الاختيار */
export default function StatusBar({ orderNo, current, steps, amount }: { orderNo: string; current: string; steps: Step[]; amount: string }) {
  const [to, setTo] = useState("");
  const step = steps.find((s) => s.to === to);
  const { state, onSubmit, pending } = useFormAction(transitionAction, () =>
    step?.to !== "cancelled" || window.confirm("تأكيد إلغاء الطلب؟"));
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
      {step?.needsBank && (
        <label className="check small"><input type="checkbox" name="bank_confirmed" required /><span>تأكدت من وصول المبلغ ({amount}) في كشف حساب المؤسسة ومطابقته لرقم الطلب.</span></label>
      )}
      <FormMessage state={state} />
    </form>
  );
}
