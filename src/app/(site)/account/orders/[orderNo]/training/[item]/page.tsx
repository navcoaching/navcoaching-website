import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { riyadhDate } from "@/lib/schedule";
import { currentWeek, effective, formatSets, planLabel } from "@/lib/training";
import { muscleAr } from "@/lib/exercises";
import { loadBlockData, type BlockRow } from "@/lib/program-data";
import VideoButton from "@/components/VideoButton";
import { ItemLogForm, SwapForm } from "../TrainingForms";

export const metadata: Metadata = { title: "تمرين", robots: { index: false } };

type SP = { week?: string; day?: string; block?: string };
type SwapOpt = { id: string; name: string; video_url: string | null; is_coach_choice: boolean; is_current: boolean };

/** صفحة التمرين الواحد: التسجيل والتبديل والفيديو وطريقة الأداء (القائمة الرئيسية تعرض الأهم فقط) */
export default async function ExercisePage({ params, searchParams }: { params: Promise<{ orderNo: string; item: string }>; searchParams: Promise<SP> }) {
  const { orderNo, item } = await params;
  const sp = await searchParams;
  const user = await requireUser(`/account/orders/${orderNo}/training`);
  const today = riyadhDate();
  const res = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, user_id FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o || o.user_id !== user.id) return null;
    const blocks = (await tx.query(
      `SELECT id, order_id, user_id, name, start_date::text, weeks, instructions, steps_goal_week, status FROM blocks
        WHERE order_id = $1 ORDER BY (status = 'active') DESC, created_at DESC`, [o.id])).rows as BlockRow[];
    const block = blocks.find((b) => b.id === sp.block) ?? blocks[0] ?? null;
    if (!block) return null;
    const data = await loadBlockData(tx, block);
    const day = data.days.find((d) => d.items.some((i) => i.id === item));
    const it = day?.items.find((i) => i.id === item);
    if (!day || !it) return null;
    const wk = currentWeek(block.start_date, today, block.weeks);
    const week = Math.min(block.weeks, Math.max(1, Number(sp.week) || wk || 1));
    const swaps = block.status === "active" ? (await tx.query(`SELECT * FROM app.swap_options($1)`, [it.id])).rows as SwapOpt[] : [];
    return { o, block, data, day, it, week, swaps };
  });
  if (!res) notFound();
  const { o, block, data, day, it, week, swaps } = res;
  const readOnly = block.status !== "active";
  const ex = data.exercises.get(it.exercise_id);
  const plan = it.plan[week - 1];
  const log = data.logs.find((l) => l.block_item_id === it.id && l.week_no === week) ?? null;
  const eff = log ? effective(log, plan) : null;
  const idx = day.items.findIndex((i) => i.id === it.id);
  const q = (over: Record<string, string> = {}) => new URLSearchParams({ week: String(week), day: day.id, ...(sp.block ? { block: sp.block } : {}), ...over }).toString();
  const back = `/account/orders/${o.order_no}/training?${q()}`;
  const next = day.items[idx + 1];
  const prev = day.items[idx - 1];
  const nameOf = (id: string) => data.exercises.get(data.days.flatMap((d) => d.items).find((i) => i.id === id)?.exercise_id ?? "")?.name ?? "—";

  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "14px" }}>
        <nav className="small"><Link href={back}>← {day.title} · الأسبوع {week}</Link></nav>
        <div className="row" style={{ justifyContent: "space-between", alignItems: "start", gap: 10 }}>
          <div>
            <h1 style={{ fontSize: "clamp(22px,4vw,30px)", margin: 0 }}><span className="muted">{idx + 1}. </span><bdi dir="ltr">{ex?.name ?? "—"}</bdi> {log && <span aria-label="مسجّل">✅</span>}</h1>
            <p className="small muted" style={{ margin: "4px 0 0" }}>{ex ? muscleAr(ex.primary_muscle) : ""}</p>
          </div>
          {ex?.video_url && <VideoButton url={ex.video_url} title={ex.name} testId="exercise-video" />}
        </div>
        <p className="target card flat" style={{ margin: 0 }} data-testid="exercise-target"><span className="muted small">المستهدف</span> <b dir="ltr">{planLabel(plan)}</b></p>
        {it.note && <p className="small alert info" style={{ margin: 0 }}>{it.note}</p>}
        {ex?.instructions && <details className="small card flat"><summary style={{ cursor: "pointer", minHeight: 36 }}>طريقة الأداء</summary><p style={{ whiteSpace: "pre-wrap", margin: "6px 0 0" }}>{ex.instructions}</p></details>}
        <div data-testid="exercise-log" className="stack" style={{ ["--space" as string]: "12px" }}>
          {eff && <p className="small muted" style={{ margin: 0 }}>{eff.oneRm > 0 && <>أعلى وزن تقديري (1RM): <b className="num">{eff.oneRm}</b> كغ · </>}<bdi dir="ltr">VLU {Math.round(eff.vlu).toLocaleString("en-US")}</bdi></p>}
          {readOnly ? (log && eff ? <p className="small">سجّلت: <bdi dir="ltr">{formatSets(eff.weights, eff.reps)}</bdi></p> : <p className="small muted">برنامج منتهي (للقراءة فقط).</p>) : (
            <>
              <ItemLogForm key={`${it.id}-${week}-${log?.logged_at ?? "new"}`} orderNo={o.order_no} item={it.id} week={week} target={plan?.reps ?? []} targetRir={plan?.rir ?? null}
                log={log ? { weight: log.weight, weights: log.weights, reps: log.reps, rir: log.rir } : null} />
              <SwapForm orderNo={o.order_no} item={it.id} current={it.exercise_id} options={swaps.map((x) => ({ id: x.id, name: x.name, is_coach_choice: x.is_coach_choice }))} />
            </>
          )}
        </div>
        <nav className="row ex-pager" style={{ justifyContent: "space-between", gap: 8 }} aria-label="التمارين">
          {next ? <Link className="btn btn-sm" href={`/account/orders/${o.order_no}/training/${next.id}?${q()}`}>التمرين التالي: <bdi dir="ltr">{nameOf(next.id)}</bdi> ←</Link> : <Link className="btn btn-sm" href={back}>رجوع لقائمة اليوم ✓</Link>}
          {prev && <Link className="btn btn-ghost btn-sm" href={`/account/orders/${o.order_no}/training/${prev.id}?${q()}`}>→ السابق</Link>}
        </nav>
      </div>
    </section>
  );
}
