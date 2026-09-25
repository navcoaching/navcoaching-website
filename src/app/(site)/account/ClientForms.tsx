"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  cancelOrderAction, submitCheckinAction, submitReviewAction, updateProfileAction, uploadProofAction,
} from "@/app/actions/client";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { authClient } from "@/lib/auth-client";

export function ClearDraft() {
  useEffect(() => { try { localStorage.removeItem("nav_checkout_draft_v2"); } catch { /* */ } }, []);
  return null;
}

export function SignOut() {
  const router = useRouter();
  return <button className="btn btn-ghost btn-sm" onClick={async () => { await authClient.signOut(); router.push("/"); router.refresh(); }}>تسجيل الخروج</button>;
}

export function ProfileForm({ name }: { name: string }) {
  const { state, onSubmit, pending } = useFormAction(updateProfileAction);
  return (
    <form onSubmit={onSubmit} className="form">
      <div className="field">
        <label htmlFor="pname">الاسم</label>
        <input id="pname" name="name" type="text" defaultValue={name} minLength={2} maxLength={80} required />
        {state.fieldErrors?.name && <span className="err-msg">{state.fieldErrors.name}</span>}
      </div>
      <FormMessage state={state} />
      <Submit pending={pending} className="btn btn-ghost btn-sm">حفظ</Submit>
    </form>
  );
}

export function UploadProofForm({ orderNo }: { orderNo: string }) {
  const { state, onSubmit, pending } = useFormAction(uploadProofAction);
  return (
    <form onSubmit={onSubmit} className="form" data-noflow>
      <input type="hidden" name="order_no" value={orderNo} />
      <div className="field">
        <label htmlFor="proof">صورة إيصال التحويل</label>
        <input id="proof" name="proof" type="file" accept="image/jpeg,image/png,image/webp,application/pdf" required />
        <span className="hint">صورة أو PDF، حتى 5 ميجابايت. لا يُعتبر طلبك مدفوعاً إلا بعد التحقق من وصول المبلغ.</span>
      </div>
      <FormMessage state={state} />
      <Submit pending={pending} className="btn btn-cyan btn-block" pendingText="جارٍ الرفع…">رفع الإيصال</Submit>
    </form>
  );
}

export function CancelForm({ orderNo }: { orderNo: string }) {
  const { state, onSubmit, pending } = useFormAction(cancelOrderAction);
  const [confirm, setConfirm] = useState(false);
  if (!confirm) return <button type="button" className="link-btn small" onClick={() => setConfirm(true)}>إلغاء الطلب</button>;
  return (
    <form onSubmit={onSubmit} className="stack">
      <input type="hidden" name="order_no" value={orderNo} />
      <p className="small">متأكد تبي تلغي الطلب؟ لا يمكن التراجع.</p>
      <FormMessage state={state} />
      <div className="row">
        <Submit pending={pending} className="btn btn-danger btn-sm">نعم، ألغِ الطلب</Submit>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setConfirm(false)}>تراجع</button>
      </div>
    </form>
  );
}

export function CheckinForm({ orderNo, questions }: { orderNo: string; questions: { topic: string; q: string }[] }) {
  const { state, onSubmit, pending } = useFormAction(submitCheckinAction);
  if (state.ok) return <FormMessage state={state} />;
  return (
    <form onSubmit={onSubmit} className="form">
      <input type="hidden" name="order_no" value={orderNo} />
      {questions.map((q, i) => (
        <div className="field" key={i}>
          <input type="hidden" name="topic" value={q.topic} />
          <input type="hidden" name="q" value={q.q} />
          <label htmlFor={`ci-${i}`}>{q.topic ? <><b>{q.topic}:</b> </> : null}{q.q}</label>
          <textarea id={`ci-${i}`} name="a" maxLength={1000} style={{ minHeight: 80 }} />
        </div>
      ))}
      <p className="hint">لا تكتب تفاصيل طبية حساسة هنا إلا إذا كانت ضرورية لبرنامجك.</p>
      <FormMessage state={state} />
      <Submit pending={pending} className="btn">أرسل المراجعة</Submit>
    </form>
  );
}

export function ReviewForm({ orderNo, name }: { orderNo: string; name: string }) {
  const { state, onSubmit, pending } = useFormAction(submitReviewAction);
  const first = name.trim().split(/\s+/)[0];
  if (state.ok) return <FormMessage state={state} />;
  const fe = state.fieldErrors ?? {};
  return (
    <form onSubmit={onSubmit} className="form">
      <input type="hidden" name="order_no" value={orderNo} />
      <fieldset className="field">
        <legend>تقييمك (اختياري)</legend>
        <div className="choices">
          {[5, 4, 3, 2, 1].map((n) => (
            <label className="choice" key={n}><input type="radio" name="rating" value={n} /><span aria-label={`${n} من 5`}>{"★".repeat(n)}</span></label>
          ))}
        </div>
      </fieldset>
      <div className="field">
        <label htmlFor="rbody">اكتب تجربتك <span className="req">*</span></label>
        <textarea id="rbody" name="body" minLength={10} maxLength={1500} required aria-invalid={fe.body ? true : undefined} />
        <span className="hint">بدون أرقام هواتف أو روابط أو تفاصيل صحية خاصة. لا نعدّل نص تقييمك أبداً.</span>
        {fe.body && <span className="err-msg">{fe.body}</span>}
      </div>
      <fieldset className="field">
        <legend>كيف يظهر اسمك إذا نُشر التقييم؟ <span className="req">*</span></legend>
        <div className="choices">
          <label className="choice"><input type="radio" name="display_mode" value="first" defaultChecked /><span>الاسم الأول فقط ({first})</span></label>
          <label className="choice"><input type="radio" name="display_mode" value="full" /><span>الاسم كامل ({name})</span></label>
          <label className="choice"><input type="radio" name="display_mode" value="anon" /><span>بدون اسم</span></label>
        </div>
      </fieldset>
      <label className="check">
        <input type="checkbox" name="consent" />
        <span>أوافق على نشر تقييمي في موقع Nav Coaching بعد المراجعة (اختياري ومنفصل — تقدر تسحب موافقتك لاحقاً).</span>
      </label>
      <FormMessage state={state} />
      <Submit pending={pending} className="btn">أرسل التقييم</Submit>
    </form>
  );
}
