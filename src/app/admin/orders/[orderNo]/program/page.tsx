import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { fmtDate, fmtDateTime } from "@/lib/format";
import { riyadhDate } from "@/lib/schedule";
import { currentWeek, normalizePlan } from "@/lib/training";
import ActionForm from "@/components/admin/ActionForm";
import ProgramEditor from "@/components/admin/ProgramEditor";
import { loadExerciseOptions, loadProgramDays, loadVolumeSetup } from "@/lib/program-data";
import VolumeTable from "@/components/admin/VolumeTable";
import {
  addBlockNoteAction, archiveBlockAction, assignTemplateAction, deleteBlockNoteAction, markSwapsSeenAction, notifyProgramAction, saveBlockAction,
} from "@/app/actions/training";
import TraineeLogs from "./TraineeLogs";
import { CHANNEL_LABEL, RESULT_LABEL, type Channel, type ChannelResult } from "@/lib/notify";

type Block = { id: string; name: string; start_date: string; weeks: number; instructions: string | null; steps_goal_week: number; status: string; created_at: string; template_name: string | null };
type Swap = { id: number; created_at: string; seen_at: string | null; week_no: number | null; from_name: string; to_name: string; day_title: string };

/** برنامج التمرين لمتدرب: إسناد قالب، تعديل البلوك له، ملاحظات، تبديلاته، وسجلاته */
export default async function OrderProgram({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<{ assigned?: string; n?: string }> }) {
  const coach = await requireCoach();
  const { orderNo } = await params;
  const sp = await searchParams;
  // نتيجة إشعار المتدرب بعد الإسناد (قيم معروفة فقط)
  const notified = (sp.n ?? "").split(",").map((x) => x.split(":") as [Channel, ChannelResult["status"]])
    .filter(([c, st]) => c in CHANNEL_LABEL && st in RESULT_LABEL).map(([c, st]) => `${CHANNEL_LABEL[c]} — ${RESULT_LABEL[st]}`);
  const data = await withUser(coach.id, async (tx) => {
    const { rows: [o] } = await tx.query(
      `SELECT o.id, o.order_no, o.user_id, o.contact_name, o.product_name, o.status FROM orders o WHERE o.order_no = $1`, [orderNo]);
    if (!o) return null;
    const blocks = (await tx.query(
      `SELECT b.id, b.name, b.start_date::text, b.weeks, b.instructions, b.steps_goal_week, b.status, b.created_at, t.name AS template_name
         FROM blocks b LEFT JOIN program_templates t ON t.id = b.template_id WHERE b.order_id = $1 ORDER BY (b.status = 'active') DESC, b.created_at DESC`, [o.id])).rows as Block[];
    const active = blocks.find((b) => b.status === "active") ?? null;
    const templates = (await tx.query(`SELECT id, name, weeks FROM program_templates WHERE NOT archived ORDER BY name`)).rows as { id: string; name: string; weeks: number }[];
    const days = active ? await loadProgramDays(tx, "block", active.id) : [];
    const notes = active ? (await tx.query(`SELECT id, week_no, body, created_at FROM block_notes WHERE block_id = $1 ORDER BY created_at DESC`, [active.id])).rows : [];
    const swaps = (await tx.query(
      `SELECT s.id, s.created_at, s.seen_at, s.week_no, f.name AS from_name, t.name AS to_name, d.title AS day_title
         FROM exercise_swaps s JOIN exercises f ON f.id = s.from_exercise_id JOIN exercises t ON t.id = s.to_exercise_id
         JOIN block_items i ON i.id = s.block_item_id JOIN block_days d ON d.id = i.day_id
         JOIN blocks b ON b.id = s.block_id WHERE b.order_id = $1 ORDER BY s.created_at DESC LIMIT 50`, [o.id])).rows as Swap[];
    return { o, blocks, active, templates, days, notes, swaps, exercises: active ? await loadExerciseOptions(tx) : [], volume: await loadVolumeSetup(tx) };
  });
  if (!data) notFound();
  const { o, blocks, active, templates, days, notes, swaps, exercises, volume } = data;
  const today = riyadhDate();
  const week = active ? currentWeek(active.start_date, today, active.weeks) : 0;
  const unseen = swaps.filter((s) => !s.seen_at).length;
  const entitled = ["active", "delivered", "completed"].includes(o.status);

  const assignForm = (
    <ActionForm action={assignTemplateAction} submit={active ? "إسناد برنامج جديد" : "إسناد البرنامج"}
      confirm={active ? "سيُنهى البرنامج الحالي (يبقى للقراءة فقط) ويبدأ برنامج جديد. متأكدة؟" : undefined}>
      <input type="hidden" name="order_no" value={o.order_no} />
      <div className="grid g3">
        <div className="field"><label htmlFor="as-tpl">القالب <span className="req">*</span></label>
          <select id="as-tpl" name="template" required defaultValue="">
            <option value="" disabled>اختاري…</option>
            {templates.map((t) => <option key={t.id} value={t.id}>{t.name} ({t.weeks} أسابيع)</option>)}
          </select></div>
        <div className="field"><label htmlFor="as-start">تاريخ البداية <span className="req">*</span></label>
          <input id="as-start" name="start_date" type="date" required defaultValue={today} /></div>
        <div className="field"><label htmlFor="as-name">اسم البرنامج (اختياري)</label>
          <input id="as-name" name="name" type="text" maxLength={120} placeholder="Block 2" /></div>
      </div>
      <label className="check"><input type="checkbox" name="notify" defaultChecked /><span>إشعار المتدرب بالبريد/واتساب</span></label>
      {templates.length === 0 && <p className="small muted">لا توجد قوالب بعد. <Link href="/admin/templates/new">أنشئي قالباً</Link> أولاً.</p>}
    </ActionForm>
  );

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1100 }}>
      <nav className="small"><Link href="/admin/orders">الطلبات</Link> / <Link href={`/admin/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link> / برنامج التمرين</nav>
      <div>
        <h1 style={{ marginBottom: 4 }}>برنامج التمرين — {o.contact_name}</h1>
        <p className="muted">{o.product_name}{active && <> · {active.name} · {week === 0 ? `يبدأ ${fmtDate(active.start_date)}` : `الأسبوع ${week} من ${active.weeks}`}</>}</p>
      </div>
      {sp.assigned && <p className="alert ok" role="status">تم إسناد البرنامج.{notified.length > 0 && ` الإشعار: ${notified.join("، ")}`}</p>}
      {!entitled && <p className="alert warn">المتدرب لا يرى البرنامج حتى تصبح حالة الطلب «نشط» أو «تم التسليم».</p>}

      {swaps.length > 0 && (
        <section className={`card stack ${unseen ? "swap-alert" : ""}`} data-testid="swaps">
          <div className="row" style={{ justifyContent: "space-between" }}>
            <h2 style={{ fontSize: 18 }}>تبديلات المتدرب {unseen > 0 && <span className="status action">{unseen} جديد</span>}</h2>
            {unseen > 0 && (
              <ActionForm action={markSwapsSeenAction} className="form" submit="اطّلعت عليها" submitClass="btn btn-ghost btn-sm">
                <input type="hidden" name="user_id" value={o.user_id} /><input type="hidden" name="back" value={`/admin/orders/${o.order_no}/program`} />
              </ActionForm>
            )}
          </div>
          <ul className="swap-list">
            {swaps.map((s) => (
              <li key={s.id} className={s.seen_at ? "" : "unseen"}>
                <span>{s.day_title}: <bdi dir="ltr">{s.from_name}</bdi> ← <bdi dir="ltr"><b>{s.to_name}</b></bdi></span>
                <span className="small muted">{fmtDateTime(s.created_at)}{s.week_no ? ` · الأسبوع ${s.week_no}` : ""}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {!active ? (
        <section className="card stack">
          <h2 style={{ fontSize: 18 }}>إسناد برنامج</h2>
          <p className="small muted">يُنسخ القالب لهذا المتدرب، ثم تقدرين تعدّلين عليه له وحده بدون ما يتأثر القالب.</p>
          {assignForm}
        </section>
      ) : (
        <>
          <details className="card">
            <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>بيانات البرنامج{active.template_name ? ` (من قالب: ${active.template_name})` : ""}</summary>
            <ActionForm action={saveBlockAction}>
              <input type="hidden" name="id" value={active.id} />
              <div className="grid g2">
                <div className="field"><label htmlFor="bk-name">الاسم</label><input id="bk-name" name="name" type="text" required maxLength={120} defaultValue={active.name} /></div>
                <div className="field"><label htmlFor="bk-start">تاريخ البداية</label><input id="bk-start" name="start_date" type="date" required defaultValue={active.start_date} /></div>
                <div className="field"><label htmlFor="bk-weeks">عدد الأسابيع</label><input id="bk-weeks" name="weeks" type="number" min={1} max={12} defaultValue={active.weeks} /></div>
                <div className="field"><label htmlFor="bk-steps">هدف الخطوات اليومي</label><input id="bk-steps" name="steps_goal_day" type="number" inputMode="numeric" min={0} max={40000} step={100} defaultValue={Math.round(active.steps_goal_week / 7)} />
                  <span className="hint">يظهر للمتدرب في «تعليمات التمرين»، والهدف الأسبوعي في التقدم = اليومي × 7.</span></div>
              </div>
              <div className="field"><label htmlFor="bk-instr">تعليمات البرنامج (تظهر للمتدرب)</label>
                <textarea id="bk-instr" name="instructions" maxLength={4000} rows={3} defaultValue={active.instructions ?? ""} /></div>
            </ActionForm>
            <div className="row" style={{ marginTop: 12 }}>
              <ActionForm action={notifyProgramAction} className="form" submit="إشعار المتدرب بتحديث البرنامج" submitClass="btn btn-ghost btn-sm">
                <input type="hidden" name="order_no" value={o.order_no} />
              </ActionForm>
              <ActionForm action={archiveBlockAction} className="form" submit="إنهاء البرنامج" submitClass="btn btn-ghost btn-sm danger"
                confirm="إنهاء البرنامج؟ يبقى ظاهراً للمتدرب للقراءة فقط ولا يقدر يسجّل عليه.">
                <input type="hidden" name="id" value={active.id} />
              </ActionForm>
            </div>
          </details>

          <section className="stack" style={{ ["--space" as string]: "10px" }}>
            <h2 style={{ fontSize: 19 }}>الأيام والتمارين</h2>
            <p className="small muted">التعديل هنا لهذا المتدرب فقط. تغيير التمرين يجعله اختيارك الجديد، وتظهر للمتدرب بدائله.</p>
            <ProgramEditor kind="block" ownerId={active.id} weeks={active.weeks}
              days={days.map((d) => ({ ...d, items: d.items.map((i) => ({ ...i, plan: normalizePlan(i.plan, active.weeks) })) }))} exercises={exercises} />
            <VolumeTable items={days.flatMap((d) => d.items.map((i) => ({ ...i, plan: normalizePlan(i.plan, active.weeks) })))} weeks={active.weeks} limits={volume.limits} saved={volume.saved} muscles={volume.muscles} />
          </section>

          <section className="card stack">
            <h2 style={{ fontSize: 18 }}>ملاحظاتك للمتدرب</h2>
            <ActionForm action={addBlockNoteAction} submit="إضافة الملاحظة" resetOnSuccess>
              <input type="hidden" name="block" value={active.id} />
              <div className="field"><label htmlFor="bn-body">الملاحظة (تظهر للمتدرب أعلى برنامجه)</label>
                <textarea id="bn-body" name="body" required maxLength={3000} rows={3} /></div>
              <div className="field"><label htmlFor="bn-week">خاصة بأسبوع؟</label>
                <select id="bn-week" name="week_no" defaultValue={week ? String(week) : ""} style={{ maxWidth: 220 }}>
                  <option value="">للبرنامج كله</option>
                  {Array.from({ length: active.weeks }, (_, i) => <option key={i} value={i + 1}>الأسبوع {i + 1}</option>)}
                </select></div>
            </ActionForm>
            {notes.map((n) => (
              <div key={n.id} className="card flat">
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <span className="small muted">{fmtDateTime(n.created_at)}{n.week_no ? ` · الأسبوع ${n.week_no}` : " · للبرنامج كله"}</span>
                  <ActionForm action={deleteBlockNoteAction} className="form" submit="حذف" submitClass="btn btn-ghost btn-sm danger" confirm="حذف الملاحظة؟">
                    <input type="hidden" name="id" value={n.id} />
                  </ActionForm>
                </div>
                <p style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", margin: 0 }}>{n.body}</p>
              </div>
            ))}
          </section>

          <TraineeLogs coachId={coach.id} blockId={active.id} userId={o.user_id} />

          <details className="card">
            <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>إسناد برنامج جديد (Block جديد)</summary>
            {assignForm}
          </details>
        </>
      )}

      {blocks.filter((b) => b.status !== "active").length > 0 && (
        <section className="card stack">
          <h2 style={{ fontSize: 17 }}>برامج سابقة</h2>
          <ul className="small" style={{ margin: 0, paddingInlineStart: 18 }}>
            {blocks.filter((b) => b.status !== "active").map((b) => <li key={b.id}>{b.name} · بدأ {fmtDate(b.start_date)} · {b.weeks} أسابيع</li>)}
          </ul>
        </section>
      )}
    </div>
  );
}
