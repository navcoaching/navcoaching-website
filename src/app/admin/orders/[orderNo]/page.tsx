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
import { AdminNotes, NotifLog, ReviewWeeks, SendReview, SubscriptionCard, loadSubscription } from "./FollowUp";
import AddonRequest from "./AddonRequest";
import StatusBar from "./StatusBar";
import { riyadhDate } from "@/lib/schedule";
import StartTag from "@/components/admin/StartTag";
import AdherenceBar from "@/components/account/AdherenceBar";
import GrantedAlert from "@/components/admin/GrantedAlert";
import { loadAdherence } from "@/lib/program-data";
import { loadReminders } from "@/lib/reminders";
import { pct } from "@/lib/adherence";
import FilePicker from "@/components/FilePicker";
import {
  addDeliverableAction, grantRewardAction, markSurveySeenAction, archiveOrderAction, deleteOrderAction, removeDeliverableAction, replyCheckinAction, coachMessageAction, requestMeasurementsAction, setAmountAction, transitionAction,
  moveOrderAction, renameMemberAction,
} from "@/app/actions/admin";
import { differentPerson } from "@/lib/names";

const show = (v: unknown) => (Array.isArray(v) ? v.join("، ") : v == null || v === "" ? "—" : String(v));

export default async function AdminOrder({ params, searchParams }: { params: Promise<{ orderNo: string }>; searchParams: Promise<{ created?: string; granted?: string; sent?: string }> }) {
  const coach = await requireCoach();
  const { orderNo } = await params;
  const { created, granted, sent } = await searchParams;
  const detail = await getOrderDetail(coach.id, orderNo);
  if (!detail) notFound();
  const { order: o, events, proofs, deliverables, checkins, intake, review } = detail;
  const answers = (intake?.answers ?? {}) as Record<string, unknown>;
  const health = (intake?.health ?? {}) as Record<string, unknown>;
  const missingMeasures = intake && (health.weight == null || health.weight === "" || health.height == null || health.height === "");
  // خمس قراءات مستقلة: تعمل بالتوازي (كل واحدة باتصالها) بدل التتابع، لأن كل رحلة إلى Neon تكلّف زمن الشبكة كاملاً
  const [currentName, actorNames, program, retention, sub] = await Promise.all([
    withUser(coach.id, async (tx) =>
      o.product_id ? (await tx.query("SELECT name FROM products WHERE id = $1", [o.product_id])).rows[0]?.name ?? null : null),
    withUser(coach.id, async (tx) =>
    Object.fromEntries((await tx.query(
      `SELECT DISTINCT e.actor_id, u.name FROM order_events e JOIN "user" u ON u.id = e.actor_id JOIN orders o ON o.id = e.order_id WHERE o.order_no = $1`,
      [orderNo])).rows.map((r) => [r.actor_id, r.name]))),
    withUser(coach.id, async (tx) => (await tx.query(
    `SELECT (SELECT name FROM blocks WHERE order_id = $1 AND status = 'active') AS active,
            (SELECT count(*)::int FROM blocks WHERE order_id = $1) AS blocks,
            (SELECT count(*)::int FROM exercise_swaps s JOIN blocks b ON b.id = s.block_id WHERE b.order_id = $1 AND s.seen_at IS NULL) AS unseen`,
    [o.id])).rows[0] as { active: string | null; blocks: number; unseen: number }),
    o.category === "follow" ? withUser(coach.id, async (tx) => {
    const r = await loadReminders(tx);
    const adherence = ["active", "completed"].includes(o.status) ? await loadAdherence(tx, o, r.review_window_days) : null;
    const links = (await tx.query(
      `SELECT order_no, status, renewal_kind, 'next' AS dir FROM orders WHERE renewal_of = $1
       UNION ALL SELECT order_no, status, NULL, 'prev' FROM orders WHERE id = $2 ORDER BY 4`, [o.id, o.renewal_of ?? null])).rows as
      { order_no: string; status: string; renewal_kind: string | null; dir: "next" | "prev" }[];
    const survey = (await tx.query(
      `SELECT wants_renewal, reason, experience, created_at, seen_at FROM exit_surveys WHERE order_id = $1`, [o.id])).rows[0] as
      { wants_renewal: boolean; reason: string; experience: string; created_at: string; seen_at: string | null } | undefined;
    return { adherence, links, survey };
  }) : Promise.resolve(null),
    loadSubscription(coach.id, o),
  ]);
  const next = coachNextSteps(o.status, o.category);
  const phoneDigits = o.contact_phone.replace(/\D/g, "");

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <nav className="small"><Link href="/admin/orders">الطلبات</Link> / <bdi className="num">{o.order_no}</bdi></nav>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div>
          <div style={{ marginBottom: 6 }}><PackageTag name={o.product_name} productId={o.product_id ?? null} currentName={currentName} /><StartTag status={o.status} pref={o.preferred_start} /></div>
          <h1 style={{ marginBottom: 4 }}>{o.product_name} — {o.offer_label}</h1>
          <p className="muted">{o.contact_name} · <bdi dir="ltr">{o.contact_phone}</bdi> · <bdi dir="ltr">{o.user_email}</bdi></p>
        </div>
        <span className="row" style={{ gap: 6 }}>{o.is_free && <span className="status ok" data-testid="free-tag">مجاني</span>}<span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span></span>
      </div>
      <StatusBar orderNo={o.order_no} current={statusLabel(o.status, o.category)} steps={next} category={o.category} today={riyadhDate()} preferredStart={o.preferred_start ?? null}
        amount={o.amount_due_halalas == null ? "—" : riyals(o.amount_due_halalas)} />
      {granted && <GrantedAlert no={granted} sent={sent === "1"} />}
      {o.is_demo && <p className="alert warn">طلب تجريبي — ليس طلباً حقيقياً.</p>}
      {checkins.some((c) => !c.replied_at) && (
        <p className="alert warn" data-testid="pending-checkin">
          📝 عند المتدرب مراجعة أسبوعية بانتظار ردك. <a href="#checkins">اقرئي إجاباته وردّي ←</a>
        </p>
      )}
      {differentPerson(o.user_name, o.contact_name, o.user_email) && (
        <p className="alert warn" data-testid="owner-mismatch">
          الطلب باسم «{o.contact_name}» لكنه في حساب «{o.user_name}» (<bdi dir="ltr">{o.user_email}</bdi>). إذا الطلب لشخص آخر انقليه لحسابه من «صاحب الحساب» أسفل الصفحة، وإلا يشوف صاحب هذا البريد برنامجه.
        </p>
      )}
      {created && <p className="alert ok" role="status">تم إنشاء الطلب يدوياً. أضيفي ملف البرنامج أو الرابط من «ملفات العميل». المتدرب يدخل ببريده <bdi dir="ltr">{o.user_email}</bdi> ويشوفه في حسابه.</p>}
      {o.source === "manual" && !intake && <p className="alert info">طلب يدوي أضافته المدربة — بدون استبيان من الموقع.</p>}

      {/* ---------- برنامج التمرين (المنصة) ---------- */}
      {o.category !== "consult" && (
        <div className="card row" style={{ justifyContent: "space-between" }} data-testid="program-card">
          <div>
            <h2 style={{ fontSize: 19, marginBottom: 4 }}>برنامج التمرين</h2>
            <p className="small muted" style={{ margin: 0 }}>
              {program.active ? <>البرنامج الحالي: <b>{program.active}</b></> : program.blocks ? "لا يوجد برنامج نشط." : "لم يُسند برنامج بعد."}
              {program.unseen > 0 && <> · <span className="status action">{program.unseen} تبديل تمرين جديد</span></>}
            </p>
          </div>
          <Link className="btn btn-sm" href={`/admin/orders/${o.order_no}/program`}>{program.active ? "فتح البرنامج والسجلات" : "إسناد برنامج"}</Link>
        </div>
      )}

      <AdminNotes coachId={coach.id} o={o} />

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
            {o.status !== "awaiting_quote" && o.status !== "payment_review" && <p className="small muted" style={{ margin: 0 }}>غيّري حالة الطلب من الشريط أعلى الصفحة.</p>}
            <a className="btn btn-ghost btn-sm" style={{ width: "fit-content" }} href={waLink(phoneDigits, `مرحباً ${o.contact_name}، بخصوص طلبك رقم ${o.order_no}`)} target="_blank" rel="noopener">مراسلة العميل على واتساب</a>
          </div>

          {/* ---------- رسالة للمتدرب ---------- */}
          {o.status !== "cancelled" && (
            <div className="card stack" data-testid="coach-message">
              <h2 style={{ fontSize: 19 }}>✉️ رسالة للمتدرب</h2>
              <ActionForm action={coachMessageAction} submit="إرسال للمتدرب" resetOnSuccess>
                <input type="hidden" name="order_no" value={o.order_no} />
                <div className="field"><label htmlFor="cm-text">الرسالة</label>
                  <textarea id="cm-text" name="text" required minLength={2} maxLength={2000} rows={3} placeholder="ملاحظة أو توجيه تبينه يوصل المتدرب…" /></div>
                <span className="hint">تظهر للمتدرب في صفحة طلبه تحت «رسائل المدربة»، ويوصله تنبيه «وصلتك رسالة» بدون نص الرسالة.</span>
              </ActionForm>
            </div>
          )}

          <ReviewWeeks o={o} d={sub} />

          <AddonRequest coachId={coach.id} orderId={o.id} />

          {/* ---------- الاستبيان (الجدول الداخلي intakes) ---------- */}
          {intake && (
            <details className="card stack intake-card" data-testid="intake">
              <summary style={{ cursor: "pointer", minHeight: 44 }}>
                <h2 style={{ fontSize: 19, display: "inline" }}>استبيان المتدرب</h2>
                {intake.health_flag && <span className="status action" style={{ marginInlineStart: 8 }}>تحتاج مراعاة</span>}
                {missingMeasures && <span className="status action" style={{ marginInlineStart: 8 }}>قياسات ناقصة</span>}
              </summary>
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
                {Object.entries(intake.answers).filter(([k]) => !["expectations", "age", "custom"].includes(k)).map(([k, v]) => <Fragment key={k}><dt>{ANSWER_LABELS[k] ?? k}</dt><dd>{show(v)}</dd></Fragment>)}
                {Array.isArray(intake.answers.custom) && (intake.answers.custom as { id: string; label: string; value: string }[]).map((c) => (
                  <Fragment key={c.id}><dt data-testid="custom-answer">{c.label}</dt><dd>{c.value}</dd></Fragment>
                ))}
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
            </details>
          )}

          {/* ---------- استبيان نهاية البرنامج (خاص بالمدربة) ---------- */}
          {retention?.survey && (
            <div className="card stack" data-testid="exit-survey-answers" style={{ ["--space" as string]: "10px" }}>
              <h2 style={{ fontSize: 19 }}>استبيان نهاية البرنامج {!retention.survey.seen_at && <span className="status action">جديد</span>}</h2>
              <p className="small muted" style={{ margin: 0 }}>{fmtDateTime(retention.survey.created_at)} · خاص بكِ ولا يُنشر</p>
              <dl className="kv small">
                <dt>رغبة بالتجديد</dt><dd><b>{retention.survey.wants_renewal ? "نعم" : "لا"}</b></dd>
                <dt>السبب</dt><dd style={{ whiteSpace: "pre-wrap" }}>{retention.survey.reason}</dd>
                <dt>تجربته</dt><dd style={{ whiteSpace: "pre-wrap" }}>{retention.survey.experience}</dd>
              </dl>
              {!retention.survey.seen_at && (
                <ActionForm action={markSurveySeenAction} submit="اطّلعت عليه" submitClass="btn btn-ghost btn-sm">
                  <input type="hidden" name="order_no" value={o.order_no} />
                </ActionForm>
              )}
            </div>
          )}

          {/* ---------- الالتزام والتجديد ---------- */}
          {retention && (retention.adherence || retention.links.length > 0) && (
            <div className="card stack" data-testid="retention-card" style={{ ["--space" as string]: "10px" }}>
              <h2 style={{ fontSize: 19 }}>الالتزام والتجديد</h2>
              {retention.adherence && <AdherenceBar a={retention.adherence} coach />}
              {retention.adherence && retention.adherence.scored > 0 && (
                <p className="small muted" style={{ margin: 0 }}>
                  آخر الأسابيع: {retention.adherence.weeks.slice(-6).map((w) => `الأسبوع ${w.no}: ${pct(w.score)}`).join("، ")}.
                  {" "}الدرجة = متوسط تسجيل التمرين والمراجعة الأسبوعية.
                </p>
              )}
              {retention.adherence?.eligible && !retention.adherence.rewarded && (
                <ActionForm action={grantRewardAction} submit="منح 3 أشهر مجاناً" confirm="منح المتدرب اشتراكاً مجانياً لـ 3 أشهر يبدأ بعد نهاية اشتراكه الحالي؟">
                  <input type="hidden" name="order_no" value={o.order_no} />
                  <input type="hidden" name="back" value={`/admin/orders/${o.order_no}`} />
                </ActionForm>
              )}
              {retention.links.map((l) => (
                <p key={l.order_no} className="small" style={{ margin: 0 }}>
                  {l.dir === "prev" ? "امتداد للاشتراك " : l.renewal_kind === "reward" ? "🎁 مكافأة الالتزام: " : "🔁 طلب تجديد: "}
                  <Link href={`/admin/orders/${l.order_no}`}><bdi className="num">{l.order_no}</bdi></Link> · {statusLabel(l.status, "follow")}
                </p>
              ))}
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
              <div className="field"><label htmlFor="dl-file">أو ملف (PDF / Excel / Word / صورة، حتى 5MB)</label><FilePicker id="dl-file" name="file" accept=".pdf,.xlsx,.docx,image/*" /></div>
            </ActionForm>
          </div>

          {/* ---------- المراجعات الأسبوعية ---------- */}
          {checkins.length > 0 && (
            <div className="card stack" id="checkins" style={{ scrollMarginTop: 90 }}>
              <h2 style={{ fontSize: 19 }}>المراجعات الأسبوعية</h2>
              {checkins.map((c) => (
                <Details key={c.id} className="card flat" defaultOpen={!c.replied_at}>
                  <summary style={{ cursor: "pointer", minHeight: 44 }}>{fmtDateTime(c.created_at)} {c.replied_at ? <span className="status ok">تم الرد</span> : <span className="status action">بانتظار ردك</span>}</summary>
                  <dl className="kv small" style={{ marginTop: 10 }}>
                    {c.answers.map((a, i) => <Fragment key={i}><dt>{a.topic || a.q}</dt><dd>{a.a || "—"}</dd></Fragment>)}
                  </dl>
                  <ActionForm action={replyCheckinAction} submit={c.replied_at ? "تحديث الرد" : "إرسال الرد"}>
                    <input type="hidden" name="id" value={c.id} /><input type="hidden" name="order_no" value={o.order_no} />
                    <div className="field"><label>ردك</label><textarea name="reply" defaultValue={c.coach_reply ?? ""} maxLength={2000} /></div>
                    {(o.video_review || c.coach_video_url) && (
                      <div className="field"><label htmlFor={`cv-${c.id}`}>🎥 رابط فيديو شرح المراجعة (اختياري)</label>
                        <input id={`cv-${c.id}`} name="video_url" type="url" dir="ltr" placeholder="https://youtu.be/… أو رابط Google Drive" defaultValue={c.coach_video_url ?? ""} maxLength={500} />
                        <span className="hint">تأكدي أن الرابط مفتوح لمن معه الرابط (غير مدرج/Unlisted).</span></div>
                    )}
                  </ActionForm>
                </Details>
              ))}
            </div>
          )}
        </div>

        <aside className="stack" style={{ ["--space" as string]: "18px" }}>
          <div className="card">
            <dl className="kv small">
              <dt>السعر</dt><dd className="num">{riyals(o.list_price_halalas)}</dd>
              <dt>المطلوب</dt><dd className="num">{o.amount_due_halalas == null ? "بانتظار التأكيد" : riyals(o.amount_due_halalas)}</dd>
              <dt>تاريخ الطلب</dt><dd>{fmtDateTime(o.created_at)}</dd>
              {o.paid_at && (<><dt>تأكيد الدفع</dt><dd>{fmtDateTime(o.paid_at)}</dd></>)}
              {review && (<><dt>التقييم</dt><dd><Link href="/admin/reviews">{review.status === "pending" ? "بانتظار المراجعة" : review.status}</Link></dd></>)}
            </dl>
          </div>
          <SubscriptionCard o={o} d={sub} />
          <SendReview o={o} d={sub} />
          {o.category !== "consult" && (
            <div className="card stack" data-testid="nutrition-card">
              <h2 style={{ fontSize: 17 }}>التغذية والمكملات</h2>
              <p className="small muted" style={{ margin: 0 }}>الأهداف اليومية، الجداول الغذائية، روتين المكملات، وسجل أكل المتدرب.</p>
              <Link className="btn btn-sm" style={{ width: "fit-content" }} href={`/admin/orders/${o.order_no}/nutrition`}>فتح التغذية والمكملات</Link>
            </div>
          )}
          <NotifLog log={sub.log} />
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
          <div className="card stack" id="owner" data-testid="owner-card">
            <h2 style={{ fontSize: 17 }}>صاحب الحساب</h2>
            <p className="small">الطلب في حساب: <b>{o.user_name || "—"}</b> · <bdi dir="ltr">{o.user_email}</bdi></p>
            <p className="small muted">من يدخل بهذا البريد يشوف هذا الطلب وبرنامجه. إذا الطلب لشخص آخر انقليه لبريده الصحيح.</p>
            <details data-testid="move-order">
              <summary className="small" style={{ cursor: "pointer", minHeight: 44 }}>نقل الطلب لحساب صاحبه الصحيح</summary>
              <ActionForm action={moveOrderAction} submit="نقل الطلب" submitClass="btn btn-sm" confirm="نقل الطلب وبرنامجه وسجلاته لهذا البريد؟ الحساب الحالي ما يعود يشوفه.">
                <input type="hidden" name="order_no" value={o.order_no} />
                <div className="field"><label htmlFor="mv-email">بريد صاحب الطلب الصحيح</label><input id="mv-email" name="email" type="email" dir="ltr" required autoComplete="off" /></div>
                <div className="field"><label htmlFor="mv-name">اسمه (لإنشاء حسابه إذا ما عنده حساب)</label><input id="mv-name" name="name" type="text" defaultValue={o.contact_name} /></div>
                <label className="check"><input type="checkbox" name="confirm" required /><span>تأكدت أن هذا البريد لصاحب الطلب</span></label>
                <p className="small muted">ينتقل الطلب مع البرنامج والسجلات والمراجعات والاستبيان. الوزن والقياسات المسجّلة في الحساب الحالي تبقى فيه.</p>
              </ActionForm>
            </details>
            <details data-testid="rename-member">
              <summary className="small" style={{ cursor: "pointer", minHeight: 44 }}>تعديل اسم صاحب الحساب</summary>
              <ActionForm action={renameMemberAction} submit="حفظ الاسم" submitClass="btn btn-ghost btn-sm">
                <input type="hidden" name="user_id" value={o.user_id} />
                <div className="field"><label htmlFor="rn-name">الاسم</label><input id="rn-name" name="name" type="text" defaultValue={o.user_name} required /></div>
              </ActionForm>
            </details>
          </div>
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
