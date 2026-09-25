"use client";
import { useFormStatus } from "react-dom";
import { startTransition, useActionState, useState } from "react";
import type { ActionState } from "@/app/actions/client";

/**
 * يرسل النموذج إلى Server Action بدون أن يمسح React الحقول بعد الرد
 * (السلوك الافتراضي لـ <form action> في React 19 يفرّغ الحقول حتى عند وجود خطأ، فيضيع ما كتبه المستخدم).
 */
export function useFormAction(fn: (s: ActionState, fd: FormData) => Promise<ActionState>, before?: (form: HTMLFormElement) => boolean) {
  const [state, dispatch, pending] = useActionState<ActionState, FormData>(fn, {});
  const onSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (pending) return;
    const form = e.currentTarget;
    if (before && !before(form)) return;
    const fd = new FormData(form, (e.nativeEvent as SubmitEvent).submitter);
    startTransition(() => dispatch(fd));
  };
  return { state, onSubmit, pending };
}

export function Submit({ children, className = "btn", pendingText = "جارٍ الإرسال…", pending: forced, ...rest }: React.ButtonHTMLAttributes<HTMLButtonElement> & { pendingText?: string; pending?: boolean }) {
  const status = useFormStatus();
  const pending = forced ?? status.pending;
  return <button type="submit" className={className} disabled={pending} aria-busy={pending} {...rest}>{pending ? pendingText : children}</button>;
}

export function FormMessage({ state }: { state: ActionState | undefined }) {
  if (!state) return null;
  if (state.error) return <p className="alert err" role="alert">{state.error}</p>;
  if (state.ok && state.message) return <p className="alert ok" role="status">{state.message}</p>;
  return null;
}

export function CopyButton({ value, label = "نسخ" }: { value: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" className="btn btn-ghost btn-sm" onClick={async () => {
      try { await navigator.clipboard.writeText(value); setDone(true); setTimeout(() => setDone(false), 1800); } catch { /* ignore */ }
    }}>{done ? "تم النسخ ✓" : label}</button>
  );
}
