import type { Metadata } from "next";
import { Fragment } from "react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/session";
import { withUser } from "@/lib/db";
import { getMyFollowUp, getOrderDetail, getSettings } from "@/lib/data";
import { SUB_LABEL, WEEKDAYS, fmtYMD, riyadhDate } from "@/lib/schedule";
import { fmtDate, fmtDateTime, riyals, waLink } from "@/lib/format";
import { ENTITLED, statusLabel, statusTone, stepIndex, timelineSteps } from "@/lib/status";
import { CopyButton } from "@/components/FormBits";
import { IconFile, IconLink } from "@/components/Icons";
import { CancelForm, CheckinForm, ClearDraft, MeasurementsForm, ReviewForm, UploadProofForm } from "../../ClientForms";

export const metadata: Metadata = { title: "تفاصيل الطلب", robots: { index: false } };

export default async function OrderPage({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<{ new?: string }> }) {
  const { orderNo } = await params;
  const user = await requireUser(`/account/orders/${orderNo}`);
  const [detail, s, sp] = await Promise.all([getOrderDetail(user.id, orderNo), getSettings(), searchParams]);
  // RLS تمنع قراءة طلب شخص آخر؛ نتحقق من الملكية هنا أيضاً (المدربة تستخدم لوحة الإدارة)
  if (!detail || detail.order.user_id !== user.id) notFound();
  const { order: o, events, proofs, deliverables, checkins, review, intake } = detail;
  const follow = await getMyFollowUp(user.id, o);
  const today = riyadhDate();
  const currentWeek = follow?.weeks.find((w) => w.status !== "done" && w.windowEnd >= today);
  const lastMissed = follow?.weeks.filter((w) => w.status === "missed").pop();
  const h = intake?.health ?? {};
  const missingMeasures = intake && o.status !== "cancelled" && (h.weight == null || h.weight === "" || h.height == null || h.height === "");

  const steps = timelineSteps(o.category, o.student_discount_requested);
  const current = o.status === "cancelled" ? -1 : stepIndex(o.status, o.category, o.student_discount_requested);
  const whenOf = (key: string) => events.find((e) => (key === "received" ? e.from_status === null : e.to_status === key))?.created_at;
  const lastRejected = proofs.find((p) => p.review_status === "rejected");
  const entitled = ENTITLED.includes(o.status);
  const waHelp = waLink(s.contact.whatsapp, `مرحباً، عندي استفسار عن طلبي رقم ${o.order_no}`);
  const amount = o.amount_due_halalas;
  const hasNutrition = entitled ? await withUser(user.id, async (tx) => (await tx.query(
    `SELECT EXISTS (SELECT 1 FROM nutrition_targets WHERE order_id = $1) OR EXISTS (SELECT 1 FROM nutrition_plans WHERE order_id = $1 AND NOT archived)
            OR EXISTS (SELECT 1 FROM supplement_routines WHERE order_id = $1 AND NOT archived) AS x`, [o.id])).rows[0].x as boolean) : false;
  const block = entitled ? await withUser(user.id, async (tx) => (await tx.query(
    `SELECT name, status FROM blocks WHERE order_id = $1 ORDER BY (status = 'active') DESC, created_at DESC LIMIT 1`, [o.id])).rows[0] as { name: string; status: string } | undefined) : undefined;

  return (
    <section className="section tight">
      {sp.new && <ClearDraft />}
      <div className="wrap stack" style={{ ["--space" as string]: "18px" }}>
        <nav className="small"><Link href="/account">طلباتي</Link> / <bdi className="num">{o.order_no}</bdi></nav>

        {sp.new && (
          <div className="alert ok" role="status">
            <div>
              <b>وصل استبيانك وتم إنشاء طلبك.</b> رقم طلبك <bdi className="num"><b>{o.order_no}</b></bdi>. احتفظ به للتواصل.
            </div>
          </div>
        )}

        <div className="row" style={{ justifyContent: "space-between" }}>
          <div>
            <h1 style={{ fontSize: "clamp(24px,4vw,34px)" }}>{o.product_name}</h1>
            <p className="muted">{o.offer_label} · طلب رقم <bdi className="num">{o.order_no}</bdi> · {fmtDate(o.created_at)}</p>
          </div>
          <span className={`status ${statusTone(o.status)}`} data-testid="order-status">{statusLabel(o.status, o.category)}</span>
        </div>

        {block && (
          <Link href={`/account/orders/${o.order_no}/training`} className="card program-link" data-testid="training-link">
            <span><b>برنامج التمرين</b><span className="small muted"> · {block.name}{block.status === "active" ? "" : " (منتهي)"}</span></span>
            <span className="btn btn-sm">سجّل تمرينك ←</span>
          </Link>
        )}

        {hasNutrition && (
          <Link href={`/account/orders/${o.order_no}/nutrition`} className="card program-link" data-testid="nutrition-link">
            <span><b>التغذية والمكملات</b><span className="small muted"> · أهدافك وجداولك وسجل يومك</span></span>
            <span className="btn btn-sm">سجّل أكلك ←</span>
          </Link>
        )}

        <div className="account-layout">
          <div className="stack" style={{ ["--space" as string]: "18px" }}>
            {/* ---------- المطلوب الآن ---------- */}
            <div className="card next-step stack" aria-labelledby="next-h">
              <h2 id="next-h" style={{ fontSize: 20 }}>الخطوة التالية</h2>

              {o.status === "awaiting_quote" && (
                <>
                  <p>طلبت خصم الطالب. أرسل إثبات الطالب (مثل البطاقة الجامعية) على واتساب، وبنأكد لك المبلغ النهائي هنا قبل التحويل.</p>
                  <a className="btn" href={waLink(s.contact.whatsapp, `مرحباً، هذا إثبات الطالب لطلبي رقم ${o.order_no}`)} target="_blank" rel="noopener">أرسل الإثبات على واتساب</a>
                  <p className="small muted">لا تحوّل قبل ما يظهر المبلغ المؤكد في هذه الصفحة.</p>
                </>
              )}

              {o.status === "awaiting_payment" && amount != null && (
                <>
                  {lastRejected?.review_note && <p className="alert err">لم يُعتمد الإيصال السابق: {lastRejected.review_note}</p>}
                  <p>حوّل <b className="num" style={{ fontSize: 20 }}>{riyals(amount)}</b> على الحساب التالي، ثم ارفع صورة الإيصال.</p>
                  <div className="bank">
                    <div><span className="muted small">اسم الحساب</span><div>{s.bank.accountName}</div></div>
                    <div><span className="muted small">البنك</span><div>{s.bank.bankName}</div></div>
                    <div><span className="muted small">الآيبان</span><div className="iban"><bdi>{s.bank.iban}</bdi></div></div>
                    <div className="row"><CopyButton value={s.bank.iban} label="نسخ الآيبان" /><CopyButton value={o.order_no} label="نسخ رقم الطلب" /></div>
                  </div>
                  <p className="small muted">اكتب رقم الطلب في ملاحظة التحويل إن أمكن.</p>
                  <UploadProofForm orderNo={o.order_no} />
                </>
              )}

              {o.status === "payment_review" && (
                <p>وصلنا إيصالك. نتحقق من وصول المبلغ في الحساب، وتتحدث حالة طلبك هنا. ما عليك أي إجراء الآن.</p>
              )}
              {o.status === "preparing" && (
                <p>{o.category === "consult" ? "تم تأكيد الدفع. بنتواصل معك لتحديد موعد الجلسة" : "تم تأكيد الدفع، ونجهّز برنامجك الآن. بنتواصل معك"} خلال {s.response_time}.</p>
              )}
              {o.status === "active" && (
                <p>برنامجك نشط. ملفاتك متاحة بالأسفل{s.checkins?.enabled && o.category === "follow" ? "، وترسل مراجعتك الأسبوعية من هذه الصفحة" : ""}.</p>
              )}
              {o.status === "delivered" && <p>ملفاتك جاهزة بالأسفل، وهي لك مدى الحياة.</p>}
              {o.status === "completed" && <p>{review ? "شكراً لك! وصلنا تقييمك." : "انتهت الخدمة. يسعدنا تكتب تقييمك لتجربتك بالأسفل."}</p>}
              {o.status === "cancelled" && <p>هذا الطلب ملغي. إذا تحتاج مساعدة تواصل معنا.</p>}

              {["awaiting_quote", "awaiting_payment"].includes(o.status) && <CancelForm orderNo={o.order_no} />}
            </div>

            {missingMeasures && (
              <div className="card stack" aria-labelledby="measure-h">
                <h2 id="measure-h" style={{ fontSize: 20 }}>أكمل قياساتك</h2>
                <p className="small muted">استبيانك ما فيه الوزن أو الطول. نحتاجها لتجهيز برنامجك بدقة، وتظهر للمدربة فقط.</p>
                <MeasurementsForm orderNo={o.order_no} />
              </div>
            )}

            {/* ---------- سجل المراجعات الأسبوعية ---------- */}
            {follow && follow.weeks.length > 0 && (
              <div className="card stack" aria-labelledby="weeks-h" data-testid="review-history">
                <h2 id="weeks-h" style={{ fontSize: 20 }}>سجل المراجعات الأسبوعية</h2>
                {currentWeek && o.status === "active" && (
                  <p className="alert info" data-testid="review-window">المراجعة مفتوحة من <b>{fmtYMD(currentWeek.windowStart)}</b> إلى <b>{fmtYMD(currentWeek.windowEnd)}</b>.</p>
                )}
                {lastMissed && o.status === "active" && (
                  <p className="alert warn" data-testid="review-missed">ما وصلتنا مراجعة الأسبوع {lastMissed.no}. ولا يهمك، متى ما تيسّر لك أرسلها أو حدّث المدربة عشان نكمل متابعتك.</p>
                )}
                <ol className="weeks">
                  {follow.weeks.map((w) => (
                    <li key={w.no} className={`wk ${w.status}`}>
                      <span aria-hidden="true">{w.status === "done" ? "✅" : w.status === "current" ? "⏳" : w.status === "missed" ? "•" : "○"}</span>
                      <span>الأسبوع {w.no} — {fmtYMD(w.due)}</span>
                      <span className="small muted">{w.status === "done" ? "تمت" : w.status === "current" ? "الأسبوع الحالي" : w.status === "missed" ? "لم تصل" : "قادم"}</span>
                    </li>
                  ))}
                </ol>
              </div>
            )}

            {/* ---------- الملفات ---------- */}
            {entitled && (
              <div className="card stack">
                <h2 style={{ fontSize: 20 }}>ملفاتي</h2>
                {deliverables.length === 0 ? (
                  <p className="muted">بتظهر ملفات برنامجك وروابطه هنا أول ما تضيفها المدربة.</p>
                ) : (
                  <ul className="stack" style={{ listStyle: "none", padding: 0, margin: 0, ["--space" as string]: "10px" }}>
                    {deliverables.map((d) => (
                      <li key={d.id}>
                        <a className="btn btn-ghost btn-block" style={{ justifyContent: "flex-start" }}
                          href={d.kind === "file" ? `/api/files/deliverable/${d.id}` : d.url!} target={d.kind === "link" ? "_blank" : undefined} rel="noopener">
                          {d.kind === "file" ? <IconFile /> : <IconLink />} {d.title}
                        </a>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )}

            {/* ---------- المراجعة الأسبوعية ---------- */}
            {o.category === "follow" && s.checkins?.enabled && (o.status === "active" || checkins.length > 0) && (
              <div className="card stack">
                <h2 style={{ fontSize: 20 }}>المراجعة الأسبوعية</h2>
                {o.status === "active" && <CheckinForm orderNo={o.order_no} questions={s.checkins.questions} />}
                {checkins.map((c) => (
                  <details key={c.id} className="card flat">
                    <summary style={{ cursor: "pointer", minHeight: 44 }}>
                      مراجعة {fmtDate(c.created_at)} — {c.coach_reply ? <span className="status ok">وصل الرد</span> : <span className="status wait">بانتظار الرد</span>}
                    </summary>
                    <dl className="kv small" style={{ marginTop: 10 }}>
                      {c.answers.map((a, i) => (<Fragment key={i}><dt>{a.topic || a.q}</dt><dd>{a.a || "—"}</dd></Fragment>))}
                    </dl>
                    {c.coach_reply && <p className="alert info" style={{ marginTop: 10 }}><b>رد المدربة:</b> {c.coach_reply}</p>}
                  </details>
                ))}
              </div>
            )}

            {/* ---------- التقييم ---------- */}
            {entitled && (
              <div className="card stack">
                <h2 style={{ fontSize: 20 }}>قيّم تجربتك</h2>
                {review ? (
                  <>
                    <p className="small muted">حالة تقييمك: {({ pending: "قيد المراجعة", published: "منشور", rejected: "لم يُنشر", hidden: "مخفي" } as Record<string, string>)[review.status]}{review.consent_publish ? "" : " (لم توافق على النشر، يظهر للمدربة فقط)"}</p>
                    <blockquote style={{ margin: 0 }}>«{review.body}»</blockquote>
                    {review.coach_reply && <p className="alert info"><b>رد المدربة:</b> {review.coach_reply}</p>}
                  </>
                ) : (
                  <ReviewForm orderNo={o.order_no} name={user.name} />
                )}
              </div>
            )}
          </div>

          <aside className="stack" style={{ ["--space" as string]: "18px" }}>
            <div className="card">
              <h2 style={{ fontSize: 18, marginBottom: 14 }}>حالة الطلب</h2>
              <ol className="timeline">
                {steps.map((st, i) => {
                  const when = whenOf(st.key);
                  const cls = current === -1 ? (when ? "done" : "") : i < current ? "done" : i === current ? "now" : "";
                  return <li key={st.key} className={cls}>{st.label}{when && <span className="when">{fmtDateTime(when)}</span>}</li>;
                })}
                {o.status === "cancelled" && <li className="now">ملغي<span className="when">{fmtDateTime(o.updated_at)}</span></li>}
              </ol>
            </div>
            <div className="card flat">
              <dl className="kv small">
                <dt>البرنامج</dt><dd>{o.product_name}</dd>
                <dt>المدة</dt><dd>{o.offer_label}</dd>
                <dt>السعر</dt><dd className="num">{riyals(o.list_price_halalas)}</dd>
                <dt>المطلوب</dt><dd className="num">{amount == null ? "بانتظار التأكيد" : riyals(amount)}</dd>
                <dt>طريقة الدفع</dt><dd>تحويل بنكي</dd>
                {o.paid_at && (<><dt>تأكيد الدفع</dt><dd>{fmtDate(o.paid_at)}</dd></>)}
                {o.sub_start_at && (<><dt>بداية الاشتراك</dt><dd data-testid="sub-start">{fmtYMD(riyadhDate(o.sub_start_at))}</dd></>)}
                {o.sub_end_at && (<><dt>نهاية الاشتراك</dt><dd data-testid="sub-end">{fmtYMD(riyadhDate(o.sub_end_at))}</dd></>)}
                {follow && (<><dt>حالة الاشتراك</dt><dd>{SUB_LABEL[follow.state]}</dd></>)}
                {o.review_weekday != null && o.sub_start_at && (<><dt>يوم المراجعة</dt><dd>{WEEKDAYS[o.review_weekday]}</dd></>)}
              </dl>
            </div>
            {events.some((e) => e.note) && (
              <div className="card flat log">
                <h2 style={{ fontSize: 16, marginBottom: 8 }}>التحديثات</h2>
                <ul style={{ margin: 0, paddingInlineStart: 18 }}>
                  {events.filter((e) => e.note).map((e) => <li key={e.id}><span className="muted">{fmtDateTime(e.created_at)}:</span> {e.note}</li>)}
                </ul>
              </div>
            )}
            <div className="card flat stack">
              <p className="small">عندك مشكلة أو سؤال عن هذا الطلب؟</p>
              <a className="btn btn-ghost btn-block" href={waHelp} target="_blank" rel="noopener">اطلب المساعدة على واتساب</a>
            </div>
          </aside>
        </div>
      </div>
    </section>
  );
}
