import { Fragment } from "react";
import type { Metadata } from "next";
import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDateTime } from "@/lib/format";
import ActionForm from "@/components/admin/ActionForm";
import Details from "@/components/admin/Details";
import { replyCheckinAction } from "@/app/actions/admin";

export const metadata: Metadata = { title: "المراجعات الأسبوعية" };

type Row = {
  id: string; order_no: string; contact_name: string; product_name: string; video_review: boolean;
  answers: { q: string; topic?: string; a: string }[]; coach_reply: string | null; coach_video_url: string | null;
  replied_at: string | null; created_at: string; n: number;
};

/** كل المراجعات الأسبوعية في مكان واحد: اللي تنتظر ردك أولاً، ثم آخر المراجعات اللي رديتي عليها */
export default async function CheckinsPage({ searchParams }: { searchParams: Promise<{ view?: string }> }) {
  const coach = await requireCoach();
  const { view } = await searchParams;
  const done = view === "done";
  const rows = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT c.id, o.order_no, o.contact_name, o.product_name, coalesce(p.video_review, false) AS video_review,
            c.answers, c.coach_reply, c.coach_video_url, c.replied_at, c.created_at,
            row_number() OVER (PARTITION BY c.order_id ORDER BY c.created_at)::int AS n
       FROM check_ins c JOIN orders o ON o.id = c.order_id LEFT JOIN products p ON p.id = o.product_id
      WHERE NOT o.is_demo AND ${done ? "c.replied_at IS NOT NULL" : "c.replied_at IS NULL"}
      ORDER BY ${done ? "c.replied_at DESC" : "c.created_at"} LIMIT 60`)).rows as Row[]);
  const pending = done ? null : rows.length;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }} data-testid="checkins-page">
      <h1>المراجعات الأسبوعية</h1>
      <nav className="tabs" aria-label="المراجعات">
        <Link href="/admin/checkins" aria-current={!done ? "true" : undefined}>بانتظار ردك{pending != null ? ` (${pending})` : ""}</Link>
        <Link href="/admin/checkins?view=done" aria-current={done ? "true" : undefined}>تم الرد</Link>
      </nav>
      {rows.length === 0 ? (
        <p className="muted card">{done ? "لا توجد مراجعات مردود عليها بعد." : "ما فيه مراجعات تنتظر ردك 👌"}</p>
      ) : rows.map((c) => (
        <div key={c.id} data-testid="checkin">
        <Details className="card stack" defaultOpen={!done}>
          <summary style={{ cursor: "pointer", minHeight: 44, display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center" }}>
            <b>{c.contact_name}</b>
            <span className="small muted">{c.product_name} · المراجعة رقم {c.n} · {fmtDateTime(c.created_at)}</span>
            {c.replied_at ? <span className="status ok">تم الرد</span> : <span className="status action">بانتظار ردك</span>}
          </summary>
          <p className="small"><Link href={`/admin/orders/${c.order_no}`}>صفحة المتدرب <bdi className="num">{c.order_no}</bdi></Link> · <Link href={`/admin/orders/${c.order_no}/program`}>برنامجه وسجلاته</Link></p>
          <dl className="kv checkin-answers">
            {c.answers.map((a, i) => <Fragment key={i}><dt>{a.topic || a.q}</dt><dd>{a.a || "—"}</dd></Fragment>)}
          </dl>
          <ActionForm action={replyCheckinAction} submit={c.replied_at ? "تحديث الرد" : "إرسال الرد"}>
            <input type="hidden" name="id" value={c.id} /><input type="hidden" name="order_no" value={c.order_no} />
            <div className="field"><label htmlFor={`r-${c.id}`}>ردك</label><textarea id={`r-${c.id}`} name="reply" defaultValue={c.coach_reply ?? ""} maxLength={2000} /></div>
            {(c.video_review || c.coach_video_url) && (
              <div className="field"><label htmlFor={`v-${c.id}`}>🎥 رابط فيديو شرح المراجعة (اختياري)</label>
                <input id={`v-${c.id}`} name="video_url" type="url" dir="ltr" placeholder="https://youtu.be/…" defaultValue={c.coach_video_url ?? ""} maxLength={500} /></div>
            )}
          </ActionForm>
        </Details>
        </div>
      ))}
    </div>
  );
}
