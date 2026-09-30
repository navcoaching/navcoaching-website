import type { Metadata } from "next";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { fmtDate, fmtDateTime } from "@/lib/format";
import { DEFAULT_REMINDERS, riyadhDate } from "@/lib/schedule";
import { currentWeek, planLabel } from "@/lib/training";
import { muscleAr } from "@/lib/exercises";
import { loadAdherence, loadBlockData, type BlockRow } from "@/lib/program-data";
import AdherenceBar from "@/components/account/AdherenceBar";
import { ImportFromImage, RateDayForm } from "./TrainingForms";
import { visionEnabled } from "@/lib/workout-vision";

export const metadata: Metadata = { title: "برنامج التمرين", robots: { index: false } };

type SP = { tab?: string; week?: string; day?: string; block?: string };

export default async function TrainingPage({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<SP> }) {
  const { orderNo } = await params;
  const sp = await searchParams;
  // الوزن والقياسات والخطوات صارت في صفحة «التقدم» (الروابط القديمة تتحوّل لها)
  if (sp.tab === "progress") redirect(`/account/orders/${encodeURIComponent(orderNo)}/progress`);
  const user = await requireUser(`/account/orders/${orderNo}/training`);
  const today = riyadhDate();

  const res = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(
      `SELECT id, order_no, user_id, product_name, status, category, months, sub_start_at, sub_end_at, review_weekday, renewal_kind FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o || o.user_id !== user.id) return null;
    // RLS: البلوك يظهر لصاحبه فقط بعد تأكيد الدفع
    const blocks = (await tx.query(
      `SELECT id, order_id, user_id, name, start_date::text, weeks, instructions, steps_goal_week, status FROM blocks
        WHERE order_id = $1 ORDER BY (status = 'active') DESC, created_at DESC`, [o.id])).rows as BlockRow[];
    const block = blocks.find((b) => b.id === sp.block) ?? blocks[0] ?? null;
    if (!block) return { o, blocks, block: null };
    const data = await loadBlockData(tx, block);
    const wk = currentWeek(block.start_date, today, block.weeks);
    const week = Math.min(block.weeks, Math.max(1, Number(sp.week) || wk || 1));
    const hasLog = (i: { id: string }) => data.logs.some((l) => l.block_item_id === i.id && l.week_no === week);
    // اليوم الافتراضي: أول يوم لم يبدأ فيه المتدرب هذا الأسبوع (إذا بدأ اليوم الأول ينتقل للثاني، وهكذا)، وإلا أول يوم ناقص
    const untouched = data.days.find((d) => d.items.length > 0 && !d.items.some(hasLog));
    const firstOpen = data.days.find((d) => d.items.some((i) => !hasLog(i)));
    const day = data.days.find((d) => d.id === sp.day) ?? untouched ?? firstOpen ?? data.days[0] ?? null;
    const { rows: [{ r }] } = await tx.query("SELECT app.review_schedule() AS r");
    const adherence = o.status === "active" && o.category === "follow"
      ? await loadAdherence(tx, o, Number(r?.review_window_days ?? DEFAULT_REMINDERS.review_window_days), today) : null;
    return { o, blocks, block, data, wk, week, day, adherence };
  });
  if (!res) notFound();
  const { o, blocks, block } = res;

  const base = `/account/orders/${o.order_no}/training`;
  if (!block) {
    return (
      <section className="section tight"><div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <Link href={`/account/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / برنامج التمرين</nav>
        <h1 style={{ fontSize: "clamp(24px,4vw,32px)" }}>برنامج التمرين</h1>
        <p className="card muted">لم يُجهَّز برنامجك على الموقع بعد. يظهر هنا بعد تأكيد الاشتراك وإسناد المدربة للبرنامج، ويصلك إشعار.</p>
      </div></section>
    );
  }
  const { data, wk, week, day, adherence } = res as Required<typeof res> & { data: NonNullable<Awaited<ReturnType<typeof loadBlockData>>> };
  const readOnly = block.status !== "active";
  const link = (over: Partial<SP>) => {
    const q = new URLSearchParams(Object.entries({ week: String(week), day: day?.id, block: sp.block, ...over }).filter(([, v]) => v) as [string, string][]);
    return `${base}?${q}`;
  };
  const notes = data.notes.filter((n) => n.week_no == null || n.week_no === week);
  const logOf = (item: string) => data.logs.find((l) => l.block_item_id === item && l.week_no === week);
  const dayDone = (d: typeof data.days[number]) => d.items.length > 0 && d.items.every((i) => data.logs.some((l) => l.block_item_id === i.id && l.week_no === week));
  const rating = day ? data.ratings.find((r) => r.block_day_id === day.id && r.week_no === week)?.rating ?? null : null;

  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <Link href={`/account/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / برنامج التمرين</nav>
        <div>
          <h1 style={{ fontSize: "clamp(22px,4vw,30px)", marginBottom: 4 }}>{block.name}</h1>
          <p className="muted" style={{ margin: 0 }} data-testid="week-label">
            {wk === 0 ? `يبدأ ${fmtDate(block.start_date)}` : `الأسبوع ${week} من ${block.weeks}`}
            {wk > 0 && week !== wk && <> · <Link href={link({ week: String(wk), day: undefined })}>الرجوع للأسبوع الحالي ({wk})</Link></>}
            {readOnly && <> · <span className="status muted">منتهي (للقراءة فقط)</span></>}
          </p>
        </div>
        {notes.length > 0 && (
          <div className="alert info stack coach-notes" style={{ ["--space" as string]: "8px" }} data-testid="coach-notes">
            <b>ملاحظات المدربة</b>
            {notes.map((n) => (
              <div key={n.id}><p style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", margin: 0 }}>{n.body}</p>
                <span className="small muted">{fmtDateTime(n.created_at)}{n.week_no ? ` · الأسبوع ${n.week_no}` : ""}</span></div>
            ))}
          </div>
        )}

        <>
            <nav className="pill-nav day-pills" aria-label="اليوم">
              {data.days.map((d) => (
                <Link key={d.id} href={link({ day: d.id })} aria-current={d.id === day?.id ? "true" : undefined}>{dayDone(d) ? "✅ " : ""}{d.title}</Link>
              ))}
            </nav>

            {day && (
              <div className="stack" style={{ ["--space" as string]: "10px" }}>
                <p className="small muted" style={{ margin: 0 }} data-testid="day-progress">
                  {day.items.filter((i) => logOf(i.id)).length} من {day.items.length} تمارين مسجّلة
                </p>
                <ol className="ex-list" data-testid="exercise-list">
                  {day.items.map((it, idx) => {
                    const ex = data.exercises.get(it.exercise_id);
                    const plan = it.plan[week - 1];
                    const log = logOf(it.id);
                    return (
                      <li key={it.id}>
                        <Link className="ex-row" href={`${base}/${it.id}?${new URLSearchParams({ week: String(week), day: day.id, ...(sp.block ? { block: sp.block } : {}) })}`} data-testid="exercise-card">
                          <span className="ex-no num">{idx + 1}</span>
                          <span className="ex-main">
                            <b><bdi dir="ltr">{ex?.name ?? "—"}</bdi></b>
                            <span className="small muted"><bdi dir="ltr">{planLabel(plan)}</bdi>{ex ? ` · ${muscleAr(ex.primary_muscle)}` : ""}</span>
                          </span>
                          {log ? <span className="ex-done" aria-label="مسجّل">✅</span> : <span className="ex-go" aria-hidden="true">←</span>}
                        </Link>
                      </li>
                    );
                  })}
                </ol>
                {!readOnly && day.items.length > 0 && (
                  <details className="card flat more-tools">
                    <summary>قيّم تمرين اليوم</summary>
                    <RateDayForm orderNo={o.order_no} day={day.id} week={week} rating={rating} />
                  </details>
                )}
              </div>
            )}

            <details className="card flat more-tools" data-testid="more-tools">
              <summary>المزيد: الأسابيع والالتزام والتعليمات</summary>
              <div className="stack" style={{ ["--space" as string]: "12px", marginTop: 10 }}>
                <div>
                  <b className="small">الأسابيع</b>
                  <nav className="pill-nav" aria-label="الأسبوع" style={{ marginTop: 6 }}>
                    {Array.from({ length: block.weeks }, (_, i) => i + 1).map((w) => (
                      <Link key={w} href={link({ week: String(w), day: undefined })} aria-current={w === week ? "true" : undefined}>
                        الأسبوع {w}{w === wk ? " ●" : ""}
                      </Link>
                    ))}
                  </nav>
                </div>
                {blocks.length > 1 && (
                  <nav className="pill-nav" aria-label="البرامج">
                    {blocks.map((b) => <Link key={b.id} href={`${base}?block=${b.id}`} aria-current={b.id === block.id ? "true" : undefined}>{b.name}{b.status === "active" ? "" : " (سابق)"}</Link>)}
                  </nav>
                )}
                {adherence && <AdherenceBar a={adherence} />}
                {block.instructions && (
                  <div><b className="small">تعليمات البرنامج</b><p style={{ whiteSpace: "pre-wrap", margin: "4px 0 0" }}>{block.instructions}</p></div>
                )}
                {!readOnly && day && day.items.length > 0 && visionEnabled() && <ImportFromImage orderNo={o.order_no} day={day.id} week={week} />}
                <p className="small" style={{ margin: 0 }}><Link href={`/account/orders/${o.order_no}/progress`}>سجّل وزنك وقياساتك وخطواتك من صفحة «التقدم» ←</Link></p>
              </div>
            </details>
        </>
      </div>
    </section>
  );
}
