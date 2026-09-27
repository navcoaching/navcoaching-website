import { withUser } from "@/lib/db";
import { fmtDateTime } from "@/lib/format";
import { loadReminders, loadWeekState, reviewMessage } from "@/lib/reminders";
import { SUB_LABEL, WEEKDAYS, WEEK_LABEL, fmtYMD, riyadhDate, subscriptionState } from "@/lib/schedule";
import { CHANNEL_LABEL, RESULT_LABEL } from "@/lib/notify";
import ActionForm from "@/components/admin/ActionForm";
import { addNoteAction, deleteNoteAction, markWeekAction, sendReviewNowAction, setSubscriptionAction } from "@/app/actions/admin";
import type { OrderRow } from "@/lib/data";

type O = OrderRow & { user_id: string; id: string };
const STATUS_TXT: Record<string, string> = { pending: "قيد الإرسال", ...RESULT_LABEL };

/** ملاحظات المدربة الخاصة: سجل بتاريخ وكاتبة كل ملاحظة. لا تُقرأ إلا بصلاحية إدارية في قاعدة البيانات */
export async function AdminNotes({ coachId, o }: { coachId: string; o: O }) {
  const notes = await withUser(coachId, async (tx) => (await tx.query(
    `SELECT n.id, n.body, n.created_at, u.name FROM order_note_entries n LEFT JOIN "user" u ON u.id = n.created_by
      WHERE n.order_id = $1 ORDER BY n.created_at DESC, n.id DESC`, [o.id])).rows as { id: string; body: string; created_at: string; name: string | null }[]);
  return (
    <section className="card stack notes-card" aria-labelledby="notes-h" data-testid="admin-notes">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h2 id="notes-h" style={{ fontSize: 19 }}>ملاحظات المدربة الخاصة 🔒 {notes.length > 0 && <span className="small muted">({notes.length})</span>}</h2>
        <span className="small muted">لا تظهر للمتدرب أبداً</span>
      </div>
      <ActionForm action={addNoteAction} submit="إضافة ملاحظة" className="form note-form" resetOnSuccess>
        <input type="hidden" name="order_no" value={o.order_no} />
        <textarea name="body" aria-label="ملاحظة جديدة" placeholder="اكتبي ملاحظة جديدة… (تُحفظ بتاريخ اليوم)" maxLength={5000} required style={{ minHeight: 90 }} />
      </ActionForm>
      {notes.length === 0 ? <p className="small muted">لا توجد ملاحظات بعد.</p> : (
        <ol className="note-log">
          {notes.map((n) => (
            <li key={n.id}>
              <div className="note-meta">
                <time dateTime={new Date(n.created_at).toISOString()}>{fmtDateTime(n.created_at)}</time>
                {n.name && <span> · {n.name}</span>}
              </div>
              <p>{n.body}</p>
              <ActionForm action={deleteNoteAction} submit="حذف" submitClass="link-btn small" className="note-del" confirm="حذف هذه الملاحظة نهائياً؟">
                <input type="hidden" name="order_no" value={o.order_no} />
                <input type="hidden" name="id" value={n.id} />
              </ActionForm>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

type SubData = Awaited<ReturnType<typeof loadSubscription>>;

/** بيانات الاشتراك والمراجعات وسجل الإشعارات (تُحمّل مرة وتُعرض في أكثر من بطاقة) */
export async function loadSubscription(coachId: string, o: O) {
  return withUser(coachId, async (tx) => {
    const r = await loadReminders(tx);
    const weeks = o.sub_start_at && o.sub_end_at
      ? await loadWeekState(tx, { id: o.id, order_no: o.order_no, user_id: o.user_id, contact_name: o.contact_name, product_name: o.product_name, sub_start_at: o.sub_start_at, sub_end_at: o.sub_end_at, review_weekday: o.review_weekday ?? null }, r)
      : [];
    const log = (await tx.query(
      `SELECT kind, channel, status, detail, body, created_at FROM notification_log WHERE order_id = $1 ORDER BY id DESC LIMIT 20`, [o.id])).rows as Log[];
    return { r, weeks, log };
  });
}

/** بطاقة الاشتراك (جانبية): الحالة والتواريخ وتعديلها */
export function SubscriptionCard({ o, d }: { o: O; d: SubData }) {
  if (o.months === 0) return null;
  const state = subscriptionState({ status: o.status, sub_start_at: o.sub_start_at ?? null, sub_end_at: o.sub_end_at ?? null }, Math.max(...d.r.sub_expiry_days));
  const today = riyadhDate();
  return (
    <div className="card stack" data-testid="subscription-card">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h2 style={{ fontSize: 17 }}>الاشتراك</h2>
        <span className={`status ${state === "active" ? "ok" : state === "ending_soon" ? "action" : "muted"}`}>{SUB_LABEL[state]}</span>
      </div>
      {o.sub_start_at && o.sub_end_at ? (
        <dl className="kv small">
          <dt>تاريخ البدء</dt><dd>{fmtYMD(riyadhDate(o.sub_start_at))}</dd>
          <dt>تاريخ الانتهاء</dt><dd>{fmtYMD(riyadhDate(o.sub_end_at))}</dd>
          <dt>يوم المراجعة</dt><dd>{o.review_weekday != null ? WEEKDAYS[o.review_weekday] : "—"}</dd>
        </dl>
      ) : <p className="small muted">يبدأ الاشتراك تلقائياً عند «تفعيل البرنامج»، وتُحسب النهاية = البدء + {o.months} {o.months === 1 ? "شهر" : "أشهر"}.</p>}
      <details>
        <summary className="small" style={{ cursor: "pointer", minHeight: 44 }}>تعديل التواريخ ويوم المراجعة</summary>
        <ActionForm action={setSubscriptionAction} submit="حفظ">
          <input type="hidden" name="order_no" value={o.order_no} />
          <div className="field"><label>تاريخ البدء</label><input type="date" name="start" required defaultValue={o.sub_start_at ? riyadhDate(o.sub_start_at) : today} /></div>
          <div className="field"><label>تاريخ الانتهاء</label><input type="date" name="end" required defaultValue={o.sub_end_at ? riyadhDate(o.sub_end_at) : ""} /></div>
          <div className="field"><label>يوم المراجعة الأسبوعية</label>
            <select name="weekday" defaultValue={o.review_weekday ?? ""}><option value="">بدون</option>{WEEKDAYS.map((d, i) => <option key={d} value={i}>{d}</option>)}</select>
          </div>
        </ActionForm>
      </details>
    </div>
  );
}

/** جدول أسابيع المراجعة (في العمود الرئيسي) */
export function ReviewWeeks({ o, d }: { o: O; d: SubData }) {
  if (o.months === 0 || d.weeks.length === 0) return null;
  return (
    <div className="card stack">
      <h2 style={{ fontSize: 18 }}>المراجعات الأسبوعية</h2>
      <p className="small muted">تُحتسب منجزة إذا أرسلها المتدرب من الموقع قرب موعدها، أو علّمتِها يدوياً. (مزامنة Google Sheets غير مفعّلة بعد.)</p>
      <div className="table-wrap">
        <table className="t" style={{ minWidth: 0 }}>
          <thead><tr><th>الأسبوع</th><th>الموعد والنافذة</th><th>الحالة</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {d.weeks.map((w) => (
              <tr key={w.no}>
                <td>{w.no}</td>
                <td className="small">{fmtYMD(w.windowStart)} → {fmtYMD(w.windowEnd)}</td>
                <td><span className={`wk ${w.status}`}>{w.status === "done" ? "✅" : w.status === "missed" ? "⚠︎" : w.status === "current" ? "⏳" : "·"} {WEEK_LABEL[w.status]}{w.source === "manual" ? " (يدوي)" : w.source === "site" ? " (من الموقع)" : ""}</span></td>
                <td>
                  {w.source !== "site" && (w.status !== "upcoming" || w.source === "manual") && (
                    <ActionForm action={markWeekAction} submit={w.source === "manual" ? "إلغاء العلامة" : "تعليم كمكتمل"} submitClass="btn btn-ghost btn-sm" className="row">
                      <input type="hidden" name="order_no" value={o.order_no} />
                      <input type="hidden" name="week" value={w.no} />
                      <input type="hidden" name="done" value={w.source === "manual" ? "0" : "1"} />
                    </ActionForm>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/** إرسال تنبيه المراجعة الآن (جانبية) */
export function SendReview({ o, d }: { o: O; d: SubData }) {
  if (o.months === 0) return null;
  const next = d.weeks.find((w) => w.status !== "done" && w.status !== "missed") ?? d.weeks.find((w) => w.status !== "done");
  const preview = reviewMessage(d.r, o.contact_name.trim().split(/\s+/)[0], next);
  return (
    <div className="card stack">
      <h2 style={{ fontSize: 17 }}>إرسال تنبيه المراجعة الآن</h2>
      <p className="small" style={{ margin: 0 }}>النص الذي سيُرسل (بريد + واتساب إن كانا مفعّلين):</p>
      <blockquote className="alert info small" style={{ margin: 0 }} data-testid="review-preview">{preview}</blockquote>
      <ActionForm action={sendReviewNowAction} submit="إرسال تنبيه المراجعة الآن" submitClass="btn btn-sm" confirm={`سيُرسل هذا النص للمتدرب:\n\n${preview}\n\nمتأكدة؟`}>
        <input type="hidden" name="order_no" value={o.order_no} />
        <p className="small muted" style={{ margin: 0 }}>لا يمكن إرسال تنبيه ثانٍ لنفس المتدرب قبل {d.r.manual_cooldown_minutes} دقائق.</p>
      </ActionForm>
    </div>
  );
}

type Log = { kind: string; channel: "email" | "whatsapp"; status: string; detail: string | null; body: string; created_at: string };

export function NotifLog({ log }: { log: Log[] }) {
  if (!log.length) return null;
  return (
    <details className="card log">
      <summary style={{ cursor: "pointer", minHeight: 44 }}>سجل الإشعارات ({log.length})</summary>
      <ul style={{ margin: 0, paddingInlineStart: 18 }}>
        {log.map((n, i) => (
          <li key={i}>{fmtDateTime(n.created_at)} · {CHANNEL_LABEL[n.channel]} · <b>{STATUS_TXT[n.status] ?? n.status}</b>{n.detail ? ` (${n.detail})` : ""}<div className="muted">{n.body.split("\n")[0]}</div></li>
        ))}
      </ul>
    </details>
  );
}
