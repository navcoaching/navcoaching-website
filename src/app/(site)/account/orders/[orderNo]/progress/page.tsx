import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { personalRecords } from "@/lib/training";
import { loadAllLifts, loadBlockData, loadBodyData, type BlockRow } from "@/lib/program-data";
import ProgressView from "@/components/training/ProgressView";
import { loadCalorieState } from "@/lib/calorie-data";
import BodyInfoForm from "./BodyInfoForm";
import { MeasureForm, StepsForm, WeightForm } from "../training/TrainingForms";
import { currentWeek } from "@/lib/training";
import { riyadhDate } from "@/lib/schedule";

export const metadata: Metadata = { title: "التقدم", robots: { index: false } };

const fmt1 = (v: number) => (Math.round(v * 10) / 10).toLocaleString("en-US");
const delta = (a: number, b: number) => { const d = Math.round((b - a) * 10) / 10; return `${d > 0 ? "+" : ""}${d.toLocaleString("en-US")}`; };
type Sub = [num: string, text: string] | null;

/** صفحة التقدم: رسوم الوزن والقياسات والخطوات، وأعلى وزن لكل تمرين. التسجيل نفسه من صفحة التمرين. */
export default async function ProgressPage({ params }: { params: Promise<{ orderNo: string }> }) {
  const { orderNo } = await params;
  const user = await requireUser(`/account/orders/${orderNo}/progress`);

  const res = await withUser(user.id, async (tx) => {
    const { rows: [o] } = await tx.query(`SELECT id, order_no, user_id, status, category FROM orders WHERE order_no = $1`, [orderNo]);
    if (!o || o.user_id !== user.id) return null;
    const { rows: [block] } = await tx.query(
      `SELECT id, order_id, user_id, name, start_date::text, weeks, instructions, steps_goal_week, status FROM blocks
        WHERE order_id = $1 ORDER BY (status = 'active') DESC, created_at DESC LIMIT 1`, [o.id]);
    const data = block ? await loadBlockData(tx, block as BlockRow) : null;
    const editable = o.category === "follow" && ["active", "delivered"].includes(o.status);
    return { o, data, body: await loadBodyData(tx, user.id), lifts: await loadAllLifts(tx, user.id), cal: editable ? await loadCalorieState(tx, o.id, user.id) : null };
  });
  if (!res) notFound();
  const { o, data, body, lifts, cal } = res;
  const today = riyadhDate();
  const active = data?.block.status === "active";
  const wk = data ? currentWeek(data.block.start_date, today, data.block.weeks) : 0;

  const w = body.weights;
  const waist = body.measurements.filter((m) => m.waist != null);
  const prs = personalRecords(lifts);
  const top = [...prs].sort((a, b) => b.best - a.best)[0];
  const stats: [string, string, Sub][] = [
    ["الوزن الحالي", w.length ? `${fmt1(w[w.length - 1].kg)} كغ` : "—", w.length > 1 ? [delta(w[0].kg, w[w.length - 1].kg), "كغ من البداية"] : null],
    ["الخصر", waist.length ? `${fmt1(waist[waist.length - 1].waist!)} سم` : "—", waist.length > 1 ? [delta(waist[0].waist!, waist[waist.length - 1].waist!), "سم من البداية"] : null],
    ["أرقام قياسية", String(prs.filter((p) => p.status === "new").length), ["", `من ${prs.length} تمرين`]],
    ["أثقل وزن", top ? `${top.best} كغ` : "—", top ? [top.name, ""] : null],
  ];

  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <Link href={`/account/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / التقدم</nav>
        <div className="row" style={{ justifyContent: "space-between", alignItems: "end" }}>
          <h1 style={{ fontSize: "clamp(24px,4vw,32px)", margin: 0 }}>التقدم</h1>
        </div>
        <div className="today-macros progress-stats" data-testid="progress-stats">
          {stats.map(([label, value, sub]) => (
            <div key={label}><span className="small muted">{label}</span><b className="num">{value}</b>{sub && <span className="small muted">{sub[0] && <bdi dir="ltr">{sub[0]}</bdi>}{sub[0] && sub[1] ? " " : ""}{sub[1]}</span>}</div>
          ))}
        </div>
        {active && data && (
          <div className="grid g3 progress-forms" data-testid="progress-forms">
            <section className="card stack"><h2 style={{ fontSize: 17 }}>سجّل وزنك</h2><WeightForm orderNo={o.order_no} today={today} /></section>
            <section className="card stack"><h2 style={{ fontSize: 17 }}>القياسات</h2><MeasureForm orderNo={o.order_no} today={today} /></section>
            <section className="card stack"><h2 style={{ fontSize: 17 }}>الخطوات</h2>
              <p className="small muted" style={{ margin: 0 }}>هدفك الأسبوعي: {data.block.steps_goal_week.toLocaleString("en-US")} خطوة</p>
              <StepsForm orderNo={o.order_no} block={data.block.id} weeks={data.block.weeks} week={wk} values={Object.fromEntries(data.steps.map((s) => [s.week_no, s.total]))} /></section>
          </div>
        )}
        <ProgressView data={data} body={body} lifts={lifts} />
        {cal && (
          <section className="card stack" aria-labelledby="bi-h">
            <h2 id="bi-h" style={{ fontSize: 18 }}>حدّث بياناتك</h2>
            <p className="small muted" style={{ margin: 0 }}>إذا تغيّر نشاطك أو أيام تمرينك، حدّثها هنا عشان تكون سعراتك مناسبة لك.</p>
            <BodyInfoForm orderNo={o.order_no} height={cal.profile.height_cm} paf={cal.profile.paf} days={cal.profile.training_days} minutes={cal.profile.minutes} />
          </section>
        )}
      </div>
    </section>
  );
}
