"use client";
import Link from "next/link";
import { requestFreePlanAction, type FreePlanState } from "@/app/actions/client";
import { Submit, useFormAction } from "@/components/FormBits";

/**
 * زر طلب الجدول: الزائر يُحوَّل لتسجيل الدخول ثم يرجع لنفس الجدول؛ المسجّل يطلبه مجاناً مرة واحدة فقط.
 * الحماية الفعلية (تسجيل الدخول، النشر، عدم التكرار) في الخادم وقاعدة البيانات، لا في هذا الزر.
 */
export default function FreePlanButton({ slug, loggedIn, owned }: { slug: string; loggedIn: boolean; owned: boolean }) {
  const { state, onSubmit, pending } = useFormAction(requestFreePlanAction as (s: FreePlanState, fd: FormData) => Promise<FreePlanState>);
  const s = state as FreePlanState;
  const back = `/free-plans/${slug}`;

  if (!loggedIn || s.needLogin) {
    return (
      <div className="stack" style={{ ["--space" as string]: "8px" }}>
        {s.needLogin && <p className="alert warn" role="alert">{s.error}</p>}
        <Link className="btn btn-block" href={`/login?next=${encodeURIComponent(back)}`}>اطلب الجدول مجانًا</Link>
        <span className="small muted">يلزم حساب مجاني: سجّل ببريدك وبترجع لهذا الجدول مباشرة.</span>
      </div>
    );
  }
  if (owned || s.owned) {
    return (
      <div className="stack" style={{ ["--space" as string]: "8px" }} data-testid="plan-owned">
        {s.ok && s.message && <p className="alert ok" role="status">{s.message}</p>}
        <Link className="btn btn-ghost btn-block" href="/account#free-plans">✓ موجود في جداولي — افتح جداولي المجانية</Link>
      </div>
    );
  }
  return (
    <form onSubmit={onSubmit} className="stack" style={{ ["--space" as string]: "8px" }}>
      <input type="hidden" name="slug" value={slug} />
      {s.error && <p className="alert err" role="alert">{s.error}</p>}
      <Submit pending={pending} className="btn btn-block" pendingText="جارٍ الطلب…">اطلب الجدول مجانًا</Submit>
    </form>
  );
}
