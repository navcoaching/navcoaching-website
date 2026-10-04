import type { Metadata } from "next";
import Link from "next/link";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { fmtDate } from "@/lib/format";
import ProfileForm from "./ProfileForm";

export const metadata: Metadata = { title: "استبيان المتدرب", robots: { index: false } };

/** يعبّي العضو استبيانه (أو يحدّثه) بدون الحاجة لطلب باقة. يبدأ من آخر استبيان محفوظ، وإلا من استبيان آخر طلب */
export default async function ProfilePage() {
  const user = await requireUser("/account/profile");
  const row = await withUser(user.id, async (tx) => {
    const own = (await tx.query("SELECT answers, health, updated_at FROM member_profiles WHERE user_id = $1", [user.id])).rows[0];
    if (own) return { ...own, saved: true } as { answers: Record<string, unknown>; health: Record<string, unknown>; updated_at: string; saved: boolean };
    const fromOrder = (await tx.query("SELECT answers, health, created_at AS updated_at FROM intakes WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1", [user.id])).rows[0];
    return fromOrder ? { ...fromOrder, saved: false } as { answers: Record<string, unknown>; health: Record<string, unknown>; updated_at: string; saved: boolean } : null;
  });
  const initial = { ...(row?.answers ?? {}), ...(row?.health ?? {}) } as Record<string, string | string[] | number>;
  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "16px", maxWidth: 820 }}>
        <nav className="small"><Link href="/account">حسابي</Link> / استبيان المتدرب</nav>
        <h1 style={{ fontSize: "clamp(24px,4vw,32px)" }}>{row?.saved ? "تحديث استبيانك" : "عبّي استبيانك"}</h1>
        <p className="muted">
          {row?.saved ? `آخر تحديث: ${fmtDate(row.updated_at)}. ` : row ? "عبّيناه من آخر طلب لك، عدّل ما تغيّر. " : ""}
          يساعد المدربة تعرف هدفك ومستواك حتى لو ما طلبت باقة بعد. لا يُلزمك بأي شيء.
        </p>
        <div className="card"><ProfileForm initial={initial} /></div>
      </div>
    </section>
  );
}
