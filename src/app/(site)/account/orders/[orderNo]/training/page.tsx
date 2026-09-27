import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { fmtDate, fmtDateTime } from "@/lib/format";
import { DEFAULT_REMINDERS, riyadhDate } from "@/lib/schedule";
import { currentWeek, effective, planLabel } from "@/lib/training";
import { muscleAr } from "@/lib/exercises";
import { loadAdherence, loadAllLifts, loadBlockData, loadBodyData, type BlockRow } from "@/lib/program-data";
import AdherenceBar from "@/components/account/AdherenceBar";
import ProgressView from "@/components/training/ProgressView";
import { ItemLogForm, MeasureForm, RateDayForm, StepsForm, SwapForm, WeightForm } from "./TrainingForms";

export const metadata: Metadata = { title: "برنامج التمرين", robots: { index: false } };

type SP = { tab?: string; week?: string; day?: string; block?: string };
type SwapOpt = { id: string; name: string; video_url: string | null; is_coach_choice: boolean; is_current: boolean };

export default async function TrainingPage({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<SP> }) {
  const { orderNo } = await params;
  const sp = await searchParams;
  const user = await requireUser(`/account/orders/${orderNo}/training`);
  const today = riyadhDate();
  const tab = sp.tab === "progress" ? "progress" : "program";

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
    const firstOpen = data.days.find((d) => d.items.some((i) => !data.logs.some((l) => l.block_item_id === i.id && l.week_no === week)));
    const day = data.days.find((d) => d.id === sp.day) ?? firstOpen ?? data.days[0] ?? null;
    const swaps = new Map<string, SwapOpt[]>();
    if (tab === "program" && day && block.status === "active") {
      for (const it of day.items) swaps.set(it.id, (await tx.query(`SELECT * FROM app.swap_options($1)`, [it.id])).rows);
    }
    const body = tab === "progress" ? await loadBodyData(tx, user.id) : null;
    const lifts = tab === "progress" ? await loadAllLifts(tx, user.id) : [];
    const { rows: [{ r }] } = await tx.query("SELECT app.review_schedule() AS r");
    const adherence = o.status === "active" && o.category === "follow"
      ? await loadAdherence(tx, o, Number(r?.review_window_days ?? DEFAULT_REMINDERS.review_window_days), today) : null;
    return { o, blocks, block, data, wk, week, day, swaps, body, lifts, adherence };
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
  const { data, wk, week, day, swaps, body, lifts, adherence } = res as Required<typeof res> & { data: NonNullable<Awaited<ReturnType<typeof loadBlockData>>> };
  const readOnly = block.status !== "active";
  const link = (over: Partial<SP>) => {
    const q = new URLSearchParams(Object.entries({ tab, week: String(week), day: day?.id, block: sp.block, ...over }).filter(([, v]) => v) as [string, string][]);
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
          <h1 style={{ fontSize: "clamp(24px,4vw,32px)", marginBottom: 4 }}>{block.name}</h1>
          <p className="muted" style={{ margin: 0 }}>
            {wk === 0 ? `يبدأ ${fmtDate(block.start_date)}` : `الأسبوع ${wk} من ${block.weeks}`} · بدأ {fmtDate(block.start_date)}
            {readOnly && <> · <span className="status muted">منتهي (للقراءة فقط)</span></>}
          </p>
        </div>
        {adherence && <AdherenceBar a={adherence} />}
        {blocks.length > 1 && (
          <nav className="pill-nav" aria-label="البرامج">
            {blocks.map((b) => <Link key={b.id} href={`${base}?block=${b.id}`} aria-current={b.id === block.id ? "true" : undefined}>{b.name}{b.status === "active" ? "" : " (سابق)"}</Link>)}
          </nav>
        )}

        {notes.length > 0 && (
          <div className="alert info stack coach-notes" style={{ ["--space" as string]: "8px" }} data-testid="coach-notes">
            <b>ملاحظات المدربة</b>
            {notes.map((n) => (
              <div key={n.id}><p style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", margin: 0 }}>{n.body}</p>
                <span className="small muted">{fmtDateTime(n.created_at)}{n.week_no ? ` · الأسبوع ${n.week_no}` : ""}</span></div>
            ))}
          </div>
        )}
        {block.instructions && (
          <details className="card"><summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>تعليمات البرنامج</summary>
            <p style={{ whiteSpace: "pre-wrap", margin: "8px 0 0" }}>{block.instructions}</p></details>
        )}

        <nav className="tabs" aria-label="أقسام البرنامج">
          <Link href={link({ tab: "program" })} aria-current={tab === "program" ? "true" : undefined}>التمارين</Link>
          <Link href={link({ tab: "progress" })} aria-current={tab === "progress" ? "true" : undefined}>التقدم والقياسات</Link>
        </nav>

        {tab === "program" ? (
          <>
            <nav className="pill-nav" aria-label="الأسبوع">
              {Array.from({ length: block.weeks }, (_, i) => i + 1).map((w) => (
                <Link key={w} href={link({ week: String(w), day: undefined })} aria-current={w === week ? "true" : undefined}>
                  الأسبوع {w}{w === wk ? " ●" : ""}
                </Link>
              ))}
            </nav>
            <nav className="pill-nav" aria-label="اليوم">
              {data.days.map((d) => (
                <Link key={d.id} href={link({ day: d.id })} aria-current={d.id === day?.id ? "true" : undefined}>{dayDone(d) ? "✅ " : ""}{d.title}</Link>
              ))}
            </nav>

            {day && (
              <div className="stack" style={{ ["--space" as string]: "12px" }}>
                <h2 style={{ fontSize: 20 }}>{day.title} <span className="small muted">— الأسبوع {week}</span></h2>
                {day.items.map((it, idx) => {
                  const ex = data.exercises.get(it.exercise_id);
                  const plan = it.plan[week - 1];
                  const log = logOf(it.id);
                  const eff = log ? effective(log, plan) : null;
                  const opts = swaps.get(it.id) ?? [];
                  return (
                    <article key={it.id} className="card stack exercise-card" style={{ ["--space" as string]: "10px" }} data-testid="exercise-card">
                      <div className="row" style={{ justifyContent: "space-between", alignItems: "start" }}>
                        <div>
                          <h3 style={{ fontSize: 18, margin: 0 }}><span className="muted">{idx + 1}. </span><bdi dir="ltr">{ex?.name ?? "—"}</bdi> {log && <span aria-label="مسجّل">✅</span>}</h3>
                          <p className="small muted" style={{ margin: "2px 0 0" }}>{ex ? muscleAr(ex.primary_muscle) : ""}</p>
                        </div>
                        {ex?.video_url && <a className="btn btn-ghost btn-sm" href={ex.video_url} target="_blank" rel="noopener noreferrer">▶ فيديو</a>}
                      </div>
                      <p className="target"><span className="muted small">المستهدف</span> <b dir="ltr">{planLabel(plan)}</b></p>
                      {it.note && <p className="small alert info" style={{ margin: 0 }}>{it.note}</p>}
                      {ex?.instructions && <details className="small"><summary style={{ cursor: "pointer", minHeight: 36 }}>طريقة الأداء</summary><p style={{ whiteSpace: "pre-wrap", margin: "6px 0 0" }}>{ex.instructions}</p></details>}
                      {eff && <p className="small muted" style={{ margin: 0 }}>VLU {Math.round(eff.vlu).toLocaleString("en-US")}</p>}
                      {readOnly ? (log ? <p className="small">سجّلت: {log.weight} كغ</p> : null) : (
                        <>
                          <ItemLogForm orderNo={o.order_no} item={it.id} week={week} target={plan?.reps ?? []} targetRir={plan?.rir ?? null}
                            log={log ? { weight: log.weight, reps: log.reps, rir: log.rir } : null} />
                          <SwapForm orderNo={o.order_no} item={it.id} current={it.exercise_id} options={opts.map((x) => ({ id: x.id, name: x.name, is_coach_choice: x.is_coach_choice }))} />
                        </>
                      )}
                    </article>
                  );
                })}
                {!readOnly && day.items.length > 0 && <div className="card"><RateDayForm orderNo={o.order_no} day={day.id} week={week} rating={rating} /></div>}
              </div>
            )}
          </>
        ) : (
          <>
            {!readOnly && (
              <div className="grid g3 progress-forms">
                <section className="card stack"><h2 style={{ fontSize: 17 }}>سجّل وزنك</h2><WeightForm orderNo={o.order_no} today={today} /></section>
                <section className="card stack"><h2 style={{ fontSize: 17 }}>القياسات</h2><MeasureForm orderNo={o.order_no} today={today} /></section>
                <section className="card stack"><h2 style={{ fontSize: 17 }}>الخطوات</h2>
                  <p className="small muted" style={{ margin: 0 }}>هدفك الأسبوعي: {block.steps_goal_week.toLocaleString("en-US")} خطوة</p>
                  <StepsForm orderNo={o.order_no} block={block.id} weeks={block.weeks} week={wk} values={Object.fromEntries(data.steps.map((s) => [s.week_no, s.total]))} /></section>
              </div>
            )}
            <ProgressView data={data} body={body!} lifts={lifts} />
          </>
        )}
      </div>
    </section>
  );
}
