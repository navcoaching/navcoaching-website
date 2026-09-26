import { Fragment } from "react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCoach } from "@/lib/session";
import { getOrderDetail } from "@/lib/data";
import { withUser } from "@/lib/db";
import { fmtDateTime, riyals, waLink } from "@/lib/format";
import { coachNextSteps, statusLabel, statusTone } from "@/lib/status";
import { ANSWER_LABELS, EXPECTATIONS_Q } from "@/lib/intake";
import ActionForm from "@/components/admin/ActionForm";
import PackageTag from "@/components/admin/PackageTag";
import Details from "@/components/admin/Details";
import { AdminNotes, Subscription } from "./FollowUp";
import {
  addDeliverableAction, archiveOrderAction, deleteOrderAction, removeDeliverableAction, replyCheckinAction, requestMeasurementsAction, setAmountAction, transitionAction,
} from "@/app/actions/admin";

const show = (v: unknown) => (Array.isArray(v) ? v.join("، ") : v == null || v === "" ? "—" : String(v));

export default async function AdminOrder({ params }: { params: Promise<{ orderNo: string }> }) {
  const coach = await requireCoach();
  const { orderNo } = await params;
  const detail = await getOrderDetail(coach.id, orderNo);
  if (!detail) notFound();
  const { order: o, events, proofs, deliverables, checkins, intake, review } = detail;
  const currentName = await withUser(coach.id, async (tx) =>
    o.product_id ? (await tx.query("SELECT name FROM products WHERE id = $1", [o.product_id])).rows[0]?.name ?? null : null);
  const answers = (intake?.answers ?? {}) as Record<string, unknown>;
  const health = (intake?.health ?? {}) as Record<string, unknown>;
  const missingMeasures = intake && (health.weight == null || health.weight === "" || health.height == null || health.height === "");
  const actorNames = await withUser(coach.id, async (tx) =>
    Object.fromEntries((await tx.query(
      `SELECT DISTINCT e.actor_id, u.name FROM order_events e JOIN "user" u ON u.id = e.actor_id JOIN orders o ON o.id = e.order_id WHERE o.order_no = $1`,
      [orderNo])).rows.map((r) => [r.actor_id, r.name])));
  const next = coachNextSteps(o.status, o.category);
  const phoneDigits = o.contact_phone.replace(/\D/g, "");

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <nav className="small"><Link href="/admin/orders">الطلبات</Link> / <bdi className="num">{o.order_no}</bdi></nav>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div>
          <div style={{ marginBottom: 6 }}><PackageTag name={o.product_name} productId={o.product_id ?? null} currentName={currentName} /></div>
          <h1 style={{ marginBottom: 4 }}>{o.product_name} — {o.offer_label}</h1>
          <p className="muted">{o.contact_name} · <bdi dir="ltr">{o.contact_phone}</bdi> · <bdi dir="ltr">{o.user_email}</bdi></p>
        </div>
        <span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span>
      </div>
      {o.is_demo && <p className="alert warn">طلب تجريبي — ليس طلباً حقيقياً.</p>}

      <div className="account-layout">
        <div className="stack" style={{ ["--space" as string]: "18px" }}>
          {/* ---------- الإجراءات ---------- */}
          <div className="card stack">
            <h2 style={{ fontSize: 19 }}>الإجراء التالي</h2>
            {o.status === "awaiting_quote" && (
              <ActionForm action={setAmountAction} submit="تأكيد المبلغ">
                <input type="hidden" name="order_no" value={o.order_no} />
                <p className="small">طلب خصم طالب. تحققي من الإثبات على واتساب ثم حددي المبلغ النهائي (السعر الأصلي {riyals(o.list_price_halalas)}). المبلغ 0 يعني مجاني، ويُنقل الطلب مباشرة إلى «قيد الإعداد».</p>
                <div className="grid g2">
                  <div className="field"><label>المبلغ النهائي (ر.س)</label><input name="amount" type="number" min={0} step="0.01" defaultValue={(o.list_price_halalas * 0.9) / 100} required /></div>
                  <div className="field"><label>ملاحظة تظهر للعميل (اختياري)</label><input name="note" type="text" maxLength={300} placeholder="خصم طالب 10%" /></div>
                </div>
              </ActionForm>
            )}
            {o.status === "payment_review" && proofs[0] && (
              <div className="alert info">
                <div>راجعي الإيصال، ثم <b>تأكدي من وصول {riyals(o.amount_due_halalas)} فعلاً في كشف الحساب</b> قبل الاعتماد — الإيصال صورة يمكن تزويرها.
                  <div style={{ marginTop: 8 }}><a className="btn btn-sm btn-ghost" href={`/api/files/proof/${proofs[0].id}`} target="_blank" rel="noopener">فتح الإيصال</a></div>
                </div>
              </div>
            )}
            {next.length === 0 && <p className="muted">لا توجد إجراءات متاحة لهذه الحالة.</p>}
            {next.map((n) => (
              <ActionForm key={n.to} action={transitionAction} submit={n.label} submitClass={n.to === "cancelled" ? "btn btn-danger btn-sm" : "btn btn-sm"}
                confirm={n.to === "cancelled" ? "تأكيد إلغاء الطلب؟" : undefined} className="form card flat">
                <input type="hidden" name="order_no" value={o.order_no} />
                <input type="hidden" name="to" value={n.to} />
                {n.needsBank && (
                  <label className="check"><input type="checkbox" name="bank_confirmed" required /><span>تأكدت من وصول المبلغ ({riyals(o.amount_due_halalas)}) في كشف حساب المؤسسة ومطابقته لرقم الطلب.</span></label>
                )}
                <div className="field">
                  <label>{n.needsNote ? "السبب (يظهر للعميل) *" : "ملاحظة تظهر للعميل (اختياري)"}</label>
                  <input name="note" type="text" maxLength={500} required={n.needsNote} />
                </div>
              </ActionForm>
            ))}
            <a className="btn btn-ghost btn-sm" style={{ width: "fit-content" }} href={waLink(phoneDigits, `مرحباً ${o.contact_name}، بخصوص طلبك رقم ${o.order_no}`)} target="_blank" rel="noopener">مراسلة العميل على واتساب</a>
          </div>

          <Subscription coachId={coach.id} o={o} />

          {/* ---------- الاستبيان (الجدول الداخلي intakes) ---------- */}
          {intake && (
            <div className="card stack">
              <h2 style={{ fontSize: 19 }}>استبيان المتدرب</h2>
              <div className="alert info" style={{ display: "block" }}>
                <b>{EXPECTATIONS_Q}</b>
                <p style={{ marginTop: 6, whiteSpace: "pre-wrap" }}>{answers.expectations ? String(answers.expectations) : "— (أُرسل الاستبيان قبل إضافة هذا السؤال)"}</p>
              </div>
              <dl className="kv">
                <dt>العمر</dt><dd>{typeof answers.age === "number" ? `${answers.age} سنة` : answers.age ? `${String(answers.age)} (نطاق من الاستبيان القديم)` : "—"}</dd>
                <dt>الوزن</dt><dd>{health.weight ? `${String(health.weight)} كغ` : "—"}</dd>
                <dt>الطول</dt><dd>{health.height ? `${String(health.height)} سم` : "—"}</dd>
              </dl>
              {missingMeasures && (
                <div className="alert warn" style={{ display: "block" }}>
                  <p>هذا المتدرب أرسل الاستبيان قبل أن يصبح الوزن والطول إلزاميين، ولم يكملهما بعد.</p>
                  <ActionForm action={requestMeasurementsAction} submit="اطلبي منه تحديثهما" submitClass="btn btn-ghost btn-sm">
                    <input type="hidden" name="order_no" value={o.order_no} />
                  </ActionForm>
                </div>
              )}
              <dl className="kv small">
                {Object.entries(intake.answers).filter(([k]) => !["expectations", "age"].includes(k)).map(([k, v]) => <Fragment key={k}><dt>{ANSWER_LABELS[k] ?? k}</dt><dd>{show(v)}</dd></Fragment>)}
                <dt>النشر في السوشل ميديا</dt><dd>{intake.media_consent}</dd>
                <dt>طلب خصم طالب</dt><dd>{o.student_discount_requested ? "نعم" : "لا"}</dd>
                <dt>ملاحظة العميل</dt><dd>{o.client_note ?? "—"}</dd>
              </dl>
              <div className={`card flat ${intake.health_flag ? "health" : ""}`}>
                <h3 style={{ fontSize: 16, marginBottom: 8 }}>البيانات الصحية والقياسات {intake.health_flag && <span className="status action">تحتاج مراعاة</span>}</h3>
                <p className="small muted" style={{ marginBottom: 8 }}>سرية — لا تُرسل في أي تنبيه أو بريد.</p>
                <dl className="kv small">
                  {Object.entries(intake.health).map(([k, v]) => <Fragment key={k}><dt>{ANSWER_LABELS[k] ?? k}</dt><dd>{show(v)}</dd></Fragment>)}
                </dl>
              </div>
            </div>
          )}

          {/* ---------- الملفات ---------- */}
          <div className="card stack">
            <h2 style={{ fontSize: 19 }}>ملفات وروابط البرنامج</h2>
            <p className="small muted">تظهر للعميل فقط عندما تكون حالة الطلب: نشط أو تم التسليم أو مكتمل. الملفات الكبيرة: استخدمي رابطاً (Google Drive مثلاً) بصلاحية «أي شخص لديه الرابط» أو مشاركة مباشرة مع بريد العميل.</p>
            {deliverables.map((d) => (
              <div key={d.id} className="row" style={{ justifyContent: "space-between" }}>
                <span>{d.kind === "file" ? <a href={`/api/files/deliverable/${d.id}`}>{d.title}</a> : <a href={d.url!} target="_blank" rel="noopener">{d.title}</a>} <span className="small muted">({d.kind === "file" ? "ملف" : "رابط"})</span></span>
                <ActionForm action={removeDeliverableAction} submit="حذف" submitClass="btn btn-danger btn-sm" className="row" confirm="حذف هذا الملف؟">
                  <input type="hidden" name="id" value={d.id} /><input type="hidden" name="order_no" value={o.order_no} />
                </ActionForm>
              </div>
            ))}
            <ActionForm action={addDeliverableAction} submit="إضافة" className="form card flat">
              <input type="hidden" name="order_no" value={o.order_no} />
              <div className="field"><label>العنوان</label><input name="title" type="text" maxLength={120} required placeholder="ملف البرنامج — الشهر الأول" /></div>
              <div className="field"><label>رابط (https)</label><input name="url" type="url" dir="ltr" placeholder="https://" /></div>
              <div className="field"><label>أو ملف (PDF / Excel / Word / صورة، حتى 5MB)</label><input name="file" type="file" accept=".pdf,.xlsx,.docx,image/*" /></div>
            </ActionForm>
          </div>

          {/* ---------- المراجعات الأسبوعية ---------- */}
          {checkins.length > 0 && (
            <div className="card stack">
              <h2 style={{ fontSize: 19 }}>المراجعات الأسبوعية</h2>
              {checkins.map((c) => (
                <Details key={c.id} className="card flat" defaultOpen={!c.coach_reply}>
                  <summary style={{ cursor: "pointer", minHeight: 44 }}>{fmtDateTime(c.created_at)} {c.coach_reply ? <span className="status ok">تم الرد</span> : <span className="status action">بانتظار ردك</span>}</summary>
                  <dl className="kv small" style={{ marginTop: 10 }}>
                    {c.answers.map((a, i) => <Fragment key={i}><dt>{a.topic || a.q}</dt><dd>{a.a || "—"}</dd></Fragment>)}
                  </dl>
                  <ActionForm action={replyCheckinAction} submit={c.coach_reply ? "تحديث الرد" : "إرسال الرد"}>
                    <input type="hidden" name="id" value={c.id} /><input type="hidden" name="order_no" value={o.order_no} />
                    <div className="field"><label>ردك</label><textarea name="reply" defaultValue={c.coach_reply ?? ""} maxLength={2000} /></div>
                  </ActionForm>
                </Details>
              ))}
            </div>
          )}
        </div>

        <aside className="stack" style={{ ["--space" as string]: "18px" }}>
          <AdminNotes coachId={coach.id} o={o} />
          <div className="card">
            <dl className="kv small">
              <dt>السعر</dt><dd className="num">{riyals(o.list_price_halalas)}</dd>
              <dt>المطلوب</dt><dd className="num">{o.amount_due_halalas == null ? "بانتظار التأكيد" : riyals(o.amount_due_halalas)}</dd>
              <dt>تاريخ الطلب</dt><dd>{fmtDateTime(o.created_at)}</dd>
              {o.paid_at && (<><dt>تأكيد الدفع</dt><dd>{fmtDateTime(o.paid_at)}</dd></>)}
              {review && (<><dt>التقييم</dt><dd><Link href="/admin/reviews">{review.status === "pending" ? "بانتظار المراجعة" : review.status}</Link></dd></>)}
            </dl>
          </div>
          {proofs.length > 0 && (
            <div className="card stack">
              <h2 style={{ fontSize: 17 }}>الإيصالات</h2>
              {proofs.map((p) => (
                <div key={p.id} className="small">
                  <a href={`/api/files/proof/${p.id}`} target="_blank" rel="noopener">إيصال {fmtDateTime(p.created_at)}</a> — {({ pending: "بانتظار المراجعة", approved: "معتمد", rejected: "مرفوض" } as Record<string, string>)[p.review_status]}
                  {p.review_note && <div className="muted">{p.review_note}</div>}
                </div>
              ))}
            </div>
          )}
          <div className="card stack">
            <h2 style={{ fontSize: 17 }}>إدارة الطلب</h2>
            {o.archived_at && <p className="small muted">هذا الطلب مخفي من قائمة الطلبات.</p>}
            <ActionForm action={archiveOrderAction} submit={o.archived_at ? "إظهار في القائمة" : "إخفاء من القائمة"} submitClass="btn btn-ghost btn-sm">
              <input type="hidden" name="order_no" value={o.order_no} />
              <input type="hidden" name="archive" value={o.archived_at ? "0" : "1"} />
              <p className="small muted">الإخفاء لا يحذف شيئاً، والعميل يرى طلبه كما هو.</p>
            </ActionForm>
            {o.status === "cancelled" ? (
              <details>
                <summary className="small" style={{ cursor: "pointer", minHeight: 44, color: "var(--err)" }}>حذف نهائي</summary>
                <ActionForm action={deleteOrderAction} submit="حذف نهائي" submitClass="btn btn-danger btn-sm">
                  <input type="hidden" name="order_no" value={o.order_no} />
                  <p className="small">يحذف الطلب واستبيانه وإيصالاته وسجله نهائياً ولا يمكن استرجاعه.</p>
                  <div className="field"><label>للتأكيد اكتبي رقم الطلب: <bdi>{o.order_no}</bdi></label><input name="confirm" type="text" dir="ltr" autoComplete="off" required /></div>
                </ActionForm>
              </details>
            ) : (
              <p className="small muted">الحذف النهائي متاح للطلبات الملغاة فقط.</p>
            )}
          </div>
          <div className="card log">
            <h2 style={{ fontSize: 17, marginBottom: 10 }}>سجل الحالة (لا يُعدّل)</h2>
            <ol className="timeline">
              {events.map((e) => (
                <li key={e.id} className="done">
                  {statusLabel(e.to_status, o.category)}
                  <span className="when">{fmtDateTime(e.created_at)} · {e.actor_role === "coach" ? `المدربة (${actorNames[e.actor_id ?? ""] ?? ""})` : e.actor_role === "client" ? "العميل" : "النظام"}</span>
                  {e.note && <span className="when">{e.note}</span>}
                </li>
              ))}
            </ol>
          </div>
        </aside>
      </div>
    </div>
  );
}
