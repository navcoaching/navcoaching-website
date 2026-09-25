"use client";
import type { ActionState } from "@/app/actions/client";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";

type Props = {
  action: (s: ActionState, fd: FormData) => Promise<ActionState>;
  children: React.ReactNode;
  submit?: string;
  submitClass?: string;
  className?: string;
  confirm?: string;
};

/** نموذج إدارة عام: يرسل إلى Server Action ويعرض النتيجة. */
export default function ActionForm({ action, children, submit = "حفظ", submitClass = "btn btn-sm", className = "form", confirm }: Props) {
  const { state, onSubmit, pending } = useFormAction(action, () => !confirm || window.confirm(confirm));
  return (
    <form className={className} onSubmit={onSubmit}>
      {children}
      <FormMessage state={state} />
      <div><Submit className={submitClass} pending={pending} pendingText="جارٍ الحفظ…">{submit}</Submit></div>
    </form>
  );
}
