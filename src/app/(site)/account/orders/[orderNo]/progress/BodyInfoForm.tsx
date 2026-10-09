"use client";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { saveMyBodyInfoAction } from "@/app/actions/calories";
import { PAF_LEVELS } from "@/lib/calories";

/** المتدرب يحدّث الطول والنشاط وأيام التمرين. المدربة تراجع أي تغيير في السعرات قبل ما يتعدّل الهدف */
export default function BodyInfoForm({ orderNo, height, paf, days, minutes }: { orderNo: string; height: number | null; paf: number; days: number; minutes: number }) {
  const { state, onSubmit, pending } = useFormAction(saveMyBodyInfoAction);
  return (
    <form onSubmit={onSubmit} className="form" data-testid="body-info-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <div className="grid g2">
        <div className="field"><label htmlFor="bi-height">الطول (سم)</label>
          <input id="bi-height" name="height" type="number" inputMode="decimal" step="0.1" min={120} max={230} dir="ltr" defaultValue={height ?? ""} /></div>
        <div className="field"><label htmlFor="bi-paf">نشاطك اليومي خارج التمرين</label>
          <select id="bi-paf" name="paf" defaultValue={Number(paf).toFixed(1)}>{PAF_LEVELS.map((o) => <option key={o.v} value={o.v}>{o.l}</option>)}</select></div>
        <div className="field"><label htmlFor="bi-days">أيام التمرين في الأسبوع</label>
          <select id="bi-days" name="days" defaultValue={String(days)}>{[0, 1, 2, 3, 4, 5, 6, 7].map((d) => <option key={d} value={d}>{d}</option>)}</select></div>
        <div className="field"><label htmlFor="bi-min">مدة جلسة التمرين</label>
          <select id="bi-min" name="minutes" defaultValue={String(minutes)}>{[30, 45, 60, 75, 90, 120].map((m) => <option key={m} value={m}>{m} دقيقة</option>)}</select></div>
      </div>
      <span className="hint">وزنك يتحدث تلقائياً من «سجّل وزنك». أي تغيير في سعراتك تراجعه المدربة قبل ما يتعدّل هدفك.</span>
      <FormMessage state={state} />
      <Submit pending={pending} className="btn btn-sm">حفظ بياناتي</Submit>
    </form>
  );
}
