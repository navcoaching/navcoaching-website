import { Fragment } from "react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requireCoach } from "@/lib/session";
import { getOrderDetail } from "@/lib/data";
import { withUser } from "@/lib/db";
import { fmtDateTime, riyals, waLink } from "@/lib/format";
import { PRE_ACTIVE, coachNextSteps, statusLabel, statusTone } from "@/lib/status";
import { ANSWER_LABELS, EXPECTATIONS_Q } from "@/lib/intake";
import ActionForm from "@/components/admin/ActionForm";
import PackageTag from "@/components/admin/PackageTag";
import Details from "@/components/admin/Details";
import { AdminNotes, NotifLog, ReviewWeeks, SendReview, SubscriptionCard, loadSubscription } from "./FollowUp";
import AddonRequest from "./AddonRequest";
import StatusBar from "./StatusBar";
import { SUB_LABEL, WEEKDAYS, daysBetween, fmtYMD, reviewEveryLabel, riyadhDate, subscriptionState } from "@/lib/schedule";
import ProgressOverview from "./ProgressOverview";
import StartTag from "@/components/admin/StartTag";
import AdherenceBar from "@/components/account/AdherenceBar";
import GrantedAlert from "@/components/admin/GrantedAlert";
import { loadAdherence } from "@/lib/program-data";
import { loadReminders } from "@/lib/reminders";
import FilePicker from "@/components/FilePicker";
import {
  addDeliverableAction, grantRewardAction, markSurveySeenAction, archiveOrderAction, deleteOrderAction, removeDeliverableAction, replyCheckinAction, coachMessageAction, requestMeasurementsAction, setAmountAction,
  moveOrderAction, renameMemberAction,
} from "@/app/actions/admin";
import { differentPerson } from "@/lib/names";
import { IconDumbbell, IconSalad, IconWhatsApp } from "@/components/Icons";

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
  const follow = o.category === "follow";
  // قبل التفعيل الحالة تحتاج متابعة يومية (أعلى الصفحة)، وبعده نادراً ما تتغير (آخر الصفحة)
  const statusTop = PRE_ACTIVE.includes(o.status);
  const statusBar = (
    <StatusBar orderNo={o.order_no} current={statusLabel(o.status, o.category)} steps={next} category={o.category} today={riyadhDate()} preferredStart={o.preferred_start ?? null}
      amount={o.amount_due_halalas == null ? "—" : riyals(o.amount_due_halalas)} />
  );
  const today = riyadhDate();
  const start = o.sub_start_at ? riyadhDate(o.sub_start_at) : null, end = o.sub_end_at ? riyadhDate(o.sub_end_at) : null;
  const totalWeeks = start && end ? Math.max(1, Math.round(daysBetween(start, end) / 7)) : 0;
  const weekNo = start && totalWeeks ? Math.min(totalWeeks, Math.max(1, Math.floor(daysBetween(start, today) / 7) + 1)) : 0;
  const left = end ? daysBetween(today, end) : null;
  const subState = o.months > 0 ? subscriptionState({ status: o.status, sub_start_at: o.sub_start_at ?? null, sub_end_at: o.sub_end_at ?? null }, Math.max(...sub.r.sub_expiry_days)) : null;
  const latest = checkins[0];
  const older = checkins.slice(1);
  const nextReview = sub.weeks.find((w) => w.status === "current" || w.status === "upcoming");
  const mismatch = differentPerson(o.user_name, o.contact_name, o.user_email);
  const intakeWeight = Number(health.weight) || null;

  const replyForm = (c: (typeof checkins)[number]) => (
    <ActionForm action={replyCheckinAction} submit={c.replied_at ? "تحديث الرد" : "إرسال الرد"}>
      <input type="hidden" name="id" value={c.id} /><input type="hidden" name="order_no" value={o.order_no} />
      <div className="field"><label htmlFor={`rp-${c.id}`} className="sr-only">ردك</label><textarea id={`rp-${c.id}`} name="reply" defaultValue={c.coach_reply ?? ""} maxLength={2000} rows={4} placeholder="ردك وتوجيهاتك للفترة الجاية…" /></div>
      <div className="field"><label htmlFor={`cv-${c.id}`}>فيديو المراجعة (اختياري)</label>
        <input id={`cv-${c.id}`} name="video_url" type="url" dir="ltr" placeholder="https://youtu.be/… أو رابط Google Drive" defaultValue={c.coach_video_url ?? ""} maxLength={500} />
        <span className="hint">ارفعي الفيديو على YouTube (غير مدرج) أو Google Drive والصقي الرابط. يظهر للمتدرب زر «شاهد فيديو شرح المراجعة».</span></div>
    </ActionForm>
  );
  const answersList = (c: (typeof checkins)[number]) => (
    <dl className="qa">
      {c.answers.map((a, i) => <div key={i}><dt>{a.topic || a.q}</dt><dd>{a.a || "—"}</dd></div>)}
    </dl>
  );

  return (
    <div className="order-page">
      <nav className="small"><Link href="/admin/orders">الطلبات</Link> / <bdi className="num">{o.order_no}</bdi></nav>

      {/* ---------- المتدرب ---------- */}
      <div className="card stack trainee-head" style={{ ["--space" as string]: "12px" }}>
        <div className="who">
          <div>
            <div className="row" style={{ gap: 6 }}>
              <PackageTag name={o.product_name} productId={o.product_id ?? null} currentName={currentName} /><span className="small muted">{o.offer_label}</span>
              <StartTag status={o.status} pref={o.preferred_start} />
              {o.is_free && <span className="status ok" data-testid="free-tag">مجاني</span>}
              <span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span>
              {subState === "ending_soon" || subState === "expired" ? <span className="status action">{SUB_LABEL[subState]}</span> : null}
            </div>
            <h1>{o.contact_name}</h1>
            <p className="small muted contact-line" style={{ margin: 0 }}><bdi dir="ltr">{o.contact_phone}</bdi> <span aria-hidden="true">·</span> <bdi dir="ltr">{o.user_email}</bdi></p>
            {follow && start && (
              <p className="prog-line" data-testid="sub-line">
                <span>الأسبوع <b>{weekNo}</b> من {totalWeeks}</span>
                {left != null && <span>{left < 0 ? "انتهى الاشتراك" : <>ينتهي <b>{fmtYMD(end!)}</b> · باقي {left} يوم</>}</span>}
                {o.review_weekday != null && <span>المراجعة: <b>{WEEKDAYS[o.review_weekday]}</b> · {reviewEveryLabel(o.review_every_weeks)}</span>}
              </p>
            )}
          </div>
          <div className="quick" data-testid="program-card">
            <a className="btn btn-sm" href={waLink(phoneDigits, `مرحباً ${o.contact_name}، بخصوص طلبك رقم ${o.order_no}`)} target="_blank" rel="noopener"><IconWhatsApp size={18} /> واتساب</a>
            {o.category !== "consult" && (
              <Link className="btn btn-ghost btn-sm" href={`/admin/orders/${o.order_no}/program`}><IconDumbbell size={18} /> {program.active ? "البرنامج والسجلات" : "إسناد برنامج"}</Link>
            )}
            {o.category !== "consult" && <span data-testid="nutrition-card"><Link className="btn btn-ghost btn-sm" href={`/admin/orders/${o.order_no}/nutrition`}><IconSalad size={18} /> التغذية والمكملات</Link></span>}
            <p className="small muted" style={{ margin: 0, flexBasis: "100%" }}>
              {program.active ? <>البرنامج الحالي: <b>{program.active}</b></> : program.blocks ? "لا يوجد برنامج نشط." : o.category !== "consult" ? "لم يُسند برنامج بعد." : ""}
              {program.unseen > 0 && <> · <span className="status action">{program.unseen} تبديل تمرين جديد</span></>}
            </p>
          </div>
        </div>
      </div>
      {/* نسخة واحدة من شريط الحالة: أعلى الصفحة قبل التفعيل، وآخرها بعده (order)، فتبقى رسالة النتيجة بعد تغيير الحالة */}
      <div className="status-slot" style={{ order: statusTop ? 0 : 1 }}>{statusBar}</div>

      {granted && <GrantedAlert no={granted} sent={sent === "1"} />}
      {o.is_demo && <p className="alert warn">طلب تجريبي — ليس طلباً حقيقياً.</p>}
      {o.status === "awaiting_quote" && (
        <div className="card stack" data-testid="quote-card">
          <h2 style={{ fontSize: 18 }}>تأكيد مبلغ خصم الطالب</h2>
          <ActionForm action={setAmountAction} submit="تأكيد المبلغ">
            <input type="hidden" name="order_no" value={o.order_no} />
            <p className="small">طلب خصم طالب. تحققي من الإثبات على واتساب ثم حددي المبلغ النهائي (السعر الأصلي {riyals(o.list_price_halalas)}). المبلغ 0 يعني مجاني، ويُنقل الطلب مباشرة إلى «قيد الإعداد».</p>
            <div className="grid g2">
              <div className="field"><label>المبلغ النهائي (ر.س)</label><input name="amount" type="number" min={0} step="0.01" defaultValue={(o.list_price_halalas * 0.9) / 100} required /></div>
              <div className="field"><label>ملاحظة تظهر للعميل (اختياري)</label><input name="note" type="text" maxLength={300} placeholder="خصم طالب 10%" /></div>
            </div>
          </ActionForm>
        </div>
      )}
      {o.status === "payment_review" && proofs[0] && (
        <div className="alert info">
          <div>راجعي الإيصال، ثم <b>تأكدي من وصول {riyals(o.amount_due_halalas)} فعلاً في كشف الحساب</b> قبل الاعتماد — الإيصال صورة يمكن تزويرها.
            <div style={{ marginTop: 8 }}><a className="btn btn-sm btn-ghost" href={`/api/files/proof/${proofs[0].id}`} target="_blank" rel="noopener">فتح الإيصال</a></div>
          </div>
        </div>
      )}
      {checkins.some((c) => !c.replied_at) && (
        <p className="alert warn" data-testid="pending-checkin">
          عند المتدرب مراجعة بانتظار ردك. <a href="#checkins">اقرئي إجاباته وردّي ←</a>
        </p>
      )}
      {mismatch && (
        <p className="alert warn" data-testid="owner-mismatch">
          الطلب باسم «{o.contact_name}» لكنه في حساب «{o.user_name}» (<bdi dir="ltr">{o.user_email}</bdi>). إذا الطلب لشخص آخر انقليه لحسابه من <a href="#owner">«صاحب الحساب»</a> أسفل الصفحة، وإلا يشوف صاحب هذا البريد برنامجه.
        </p>
      )}
      {created && <p className="alert ok" role="status">تم إنشاء الطلب يدوياً. أضيفي ملف البرنامج أو الرابط من «ملفات وروابط البرنامج». المتدرب يدخل ببريده <bdi dir="ltr">{o.user_email}</bdi> ويشوفه في حسابه.</p>}
      {o.source === "manual" && !intake && <p className="alert info">طلب يدوي أضافته المدربة — بدون استبيان من الموقع.</p>}

      <nav className="secnav" aria-label="أقسام الصفحة">
        {follow && start && <a href="#progress">التقدم</a>}
        {follow && <a href="#checkins">المراجعات</a>}
        <a href="#notes">الملاحظات والرسائل</a>
        <a href="#more">الاستبيان والطلب</a>
      </nav>

      {/* ---------- تطور المتدرب ---------- */}
      {follow && start && (
        <ProgressOverview coachId={coach.id} o={o} adherence={retention?.adherence ?? null} weeks={sub.weeks} intakeWeight={intakeWeight} />
      )}

      {/* ---------- المراجعات ---------- */}
      {follow && (
        <section id="checkins" className="stack" style={{ ["--space" as string]: "14px", scrollMarginTop: 70 }}>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <h2 style={{ fontSize: 20 }}>{(o.review_every_weeks ?? 1) > 1 ? `المراجعات (${reviewEveryLabel(o.review_every_weeks)})` : "المراجعات الأسبوعية"}</h2>
            {nextReview && <span className="small muted">الموعد القادم: {fmtYMD(nextReview.due)}</span>}
          </div>
          {latest ? (
            <div className="two">
              <section className="card stack" style={{ ["--space" as string]: "10px" }} data-testid="latest-checkin">
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <h3 style={{ fontSize: 17 }}>آخر مراجعة · {fmtDateTime(latest.created_at)}</h3>
                  {latest.replied_at ? <span className="status ok">تم الرد</span> : <span className="status action">بانتظار ردك</span>}
                </div>
                {answersList(latest)}
              </section>
              <section className="card stack" style={{ ["--space" as string]: "10px" }}>
                <h3 style={{ fontSize: 17 }}>{latest.replied_at ? "ردك" : "اكتبي ردك"}</h3>
                {replyForm(latest)}
              </section>
            </div>
          ) : <p className="card muted small">ما أرسل المتدرب أي مراجعة بعد.</p>}
          {older.length > 0 && (
            <details className="fold">
              <summary>المراجعات السابقة <small>{older.length} مراجعة</small></summary>
              <div className="stack fold-body" style={{ ["--space" as string]: "10px" }}>
                {older.map((c) => (
                  <Details key={c.id} className="card flat" defaultOpen={!c.replied_at}>
                    <summary style={{ cursor: "pointer", minHeight: 44 }}>{fmtDateTime(c.created_at)} {c.replied_at ? <span className="status ok">تم الرد</span> : <span className="status action">بانتظار ردك</span>}</summary>
                    <div style={{ marginTop: 10 }}>{answersList(c)}</div>
                    {replyForm(c)}
                  </Details>
                ))}
              </div>
            </details>
          )}
          {sub.weeks.length > 0 && (
            <details className="fold">
              <summary>جدول المواعيد <small>تمت {sub.weeks.filter((w) => w.status === "done").length} · • {sub.weeks.filter((w) => w.status === "missed").length} · من {sub.weeks.length}</small></summary>
              <div className="fold-body stack" style={{ ["--space" as string]: "12px" }}><ReviewWeeks o={o} d={sub} /><SendReview o={o} d={sub} /></div>
            </details>
          )}
        </section>
      )}

      <AddonRequest coachId={coach.id} orderId={o.id} />

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
          <h2 style={{ fontSize: 19 }}>المكافأة والتجديد</h2>
          {retention.adherence && <AdherenceBar a={retention.adherence} coach />}
          {retention.adherence?.eligible && !retention.adherence.rewarded && (
            <ActionForm action={grantRewardAction} submit="منح 3 أشهر مجاناً" confirm="منح المتدرب اشتراكاً مجانياً لـ 3 أشهر يبدأ بعد نهاية اشتراكه الحالي؟">
              <input type="hidden" name="order_no" value={o.order_no} />
              <input type="hidden" name="back" value={`/admin/orders/${o.order_no}`} />
            </ActionForm>
          )}
          {retention.links.map((l) => (
            <p key={l.order_no} className="small" style={{ margin: 0 }}>
              {l.dir === "prev" ? "امتداد للاشتراك " : l.renewal_kind === "reward" ? "مكافأة الالتزام: " : "طلب تجديد: "}
              <Link href={`/admin/orders/${l.order_no}`}><bdi className="num">{l.order_no}</bdi></Link> · {statusLabel(l.status, "follow")}
            </p>
          ))}
        </div>
      )}

      {/* ---------- الملاحظات والرسائل ---------- */}
      <section id="notes" className="two" style={{ scrollMarginTop: 70 }}>
        <AdminNotes coachId={coach.id} o={o} />
        {o.status !== "cancelled" && (
          <div className="card stack" data-testid="coach-message">
            <h2 style={{ fontSize: 19 }}>رسالة للمتدرب</h2>
            <ActionForm action={coachMessageAction} submit="إرسال للمتدرب" resetOnSuccess>
              <input type="hidden" name="order_no" value={o.order_no} />
              <div className="field"><label htmlFor="cm-text">الرسالة</label>
                <textarea id="cm-text" name="text" required minLength={2} maxLength={2000} rows={3} placeholder="ملاحظة أو توجيه تبينه يوصل المتدرب…" /></div>
              <span className="hint">تظهر للمتدرب في صفحة طلبه تحت «رسائل المدربة»، ويوصله تنبيه «وصلتك رسالة» بدون نص الرسالة.</span>
            </ActionForm>
          </div>
        )}
      </section>

      {/* ---------- الاستبيان والطلب (مطوية) ---------- */}
      <section id="more" className="folds" style={{ scrollMarginTop: 70 }}>
        <h2 style={{ fontSize: 20 }}>الاستبيان والطلب</h2>
        {intake && (
          <details className="fold intake-card" data-testid="intake">
            <summary>
              <span>استبيان المتدرب</span>
              <small>
                {intake.health_flag && <span className="status action">تحتاج مراعاة</span>}
                {missingMeasures && <span className="status action" style={{ marginInlineStart: 6 }}>قياسات ناقصة</span>}
              </small>
            </summary>
            <div className="fold-body stack" style={{ ["--space" as string]: "12px" }}>
              <p className="row small" style={{ justifyContent: "space-between" }}>
                <span className="muted">ملف نصي مرتب (Markdown) للقراءة أو لرفعه لأداة ذكاء اصطناعي. بدون الجوال والبريد، وفيه البيانات الصحية.</span>
                <a href={`/admin/orders/${o.order_no}/intake`} download className="btn btn-ghost btn-sm" data-testid="intake-export">تصدير الاستبيان</a>
              </p>
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
            </div>
          </details>
        )}

        <details className="fold" open={Boolean(created) || undefined}>
          <summary><span>ملفات وروابط البرنامج</span><small>{deliverables.length ? `${deliverables.length} ملف` : "لا يوجد"}</small></summary>
          <div className="fold-body stack">
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
        </details>

        {o.months > 0 && (
          <details className="fold">
            <summary><span>الاشتراك والتواريخ</span><small>{start && end ? `${fmtYMD(start)} ← ${fmtYMD(end)}` : "لم يبدأ"}</small></summary>
            <div className="fold-body"><SubscriptionCard o={o} d={sub} /></div>
          </details>
        )}

        <details className="fold">
          <summary><span>الإشعارات المرسلة</span><small>{sub.log.length ? `${sub.log.length} إشعار` : "لا يوجد"}</small></summary>
          <div className="fold-body"><NotifLog log={sub.log} /></div>
        </details>

        <details className="fold">
          <summary><span>الدفع والإيصالات</span><small>{o.amount_due_halalas == null ? "بانتظار التأكيد" : riyals(o.amount_due_halalas)}{proofs.length ? ` · ${proofs.length} إيصال` : ""}</small></summary>
          <div className="fold-body stack">
            <dl className="kv small">
              <dt>السعر</dt><dd className="num">{riyals(o.list_price_halalas)}</dd>
              <dt>المطلوب</dt><dd className="num">{o.amount_due_halalas == null ? "بانتظار التأكيد" : riyals(o.amount_due_halalas)}</dd>
              <dt>تاريخ الطلب</dt><dd>{fmtDateTime(o.created_at)}</dd>
              {o.paid_at && (<><dt>تأكيد الدفع</dt><dd>{fmtDateTime(o.paid_at)}</dd></>)}
              {review && (<><dt>التقييم</dt><dd><Link href="/admin/reviews">{review.status === "pending" ? "بانتظار المراجعة" : review.status}</Link></dd></>)}
            </dl>
            {proofs.map((p) => (
              <div key={p.id} className="small">
                <a href={`/api/files/proof/${p.id}`} target="_blank" rel="noopener">إيصال {fmtDateTime(p.created_at)}</a> — {({ pending: "بانتظار المراجعة", approved: "معتمد", rejected: "مرفوض" } as Record<string, string>)[p.review_status]}
                {p.review_note && <div className="muted">{p.review_note}</div>}
              </div>
            ))}
          </div>
        </details>

        <Details className="fold" id="owner" defaultOpen={mismatch}>
          <summary><span>صاحب الحساب</span><small>نقل الطلب · تعديل الاسم</small></summary>
          <div className="fold-body stack" data-testid="owner-card">
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
        </Details>

        <details className="fold">
          <summary><span>إدارة الطلب وسجل الحالة</span><small>{o.archived_at ? "مخفي من القائمة" : "إخفاء · حذف"}</small></summary>
          <div className="fold-body stack">
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
            <div className="log">
              <h3 style={{ fontSize: 16, marginBottom: 10 }}>سجل الحالة (لا يُعدّل)</h3>
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
          </div>
        </details>

      </section>
    </div>
  );
}
