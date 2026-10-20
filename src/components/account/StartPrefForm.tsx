"use client";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import StartPrefFields from "@/components/StartPrefFields";
import { setStartPrefAction } from "@/app/actions/client";

/** المتدرب يغيّر موعد بداية برنامجه قبل التفعيل */
export default function StartPrefForm({ orderNo, pref }: { orderNo: string; pref: string | null }) {
  const { state, onSubmit, pending } = useFormAction(setStartPrefAction);
  return (
    <form onSubmit={onSubmit} className="form" data-testid="start-pref-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <StartPrefFields initial={pref} idPrefix="acc-start" error={state.fieldErrors?.start_date} />
      <FormMessage state={state} />
      <Submit pending={pending} className="btn btn-ghost btn-sm">حفظ الموعد</Submit>
    </form>
  );
}
