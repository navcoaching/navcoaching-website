"use client";
import { useEffect, useRef } from "react";
import type { ActionState } from "@/app/actions/client";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";

type Props = {
  action: (s: ActionState, fd: FormData) => Promise<ActionState>;
  children: React.ReactNode;
  submit?: string;
  submitClass?: string;
  className?: string;
  confirm?: string;
  /** تفريغ الحقول بعد النجاح (مثل إضافة ملاحظة جديدة) */
  resetOnSuccess?: boolean;
};

/** نموذج إدارة عام: يرسل إلى Server Action ويعرض النتيجة. */
export default function ActionForm({ action, children, submit = "حفظ", submitClass = "btn btn-sm", className = "form", confirm, resetOnSuccess }: Props) {
  const { state, onSubmit, pending } = useFormAction(action, () => !confirm || window.confirm(confirm));
  const ref = useRef<HTMLFormElement>(null);
  useEffect(() => { if (resetOnSuccess && state.ok) ref.current?.reset(); }, [state, resetOnSuccess]);
  return (
    <form ref={ref} className={className} onSubmit={onSubmit}>
      {children}
      <FormMessage state={state} />
      <div><Submit className={submitClass} pending={pending} pendingText="جارٍ الحفظ…">{submit}</Submit></div>
    </form>
  );
}
