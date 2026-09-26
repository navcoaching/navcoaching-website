import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { mailConfigured } from "@/lib/mail";
import { fmtDate, riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import { getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";
import { whatsappConfigured } from "@/lib/notify";
import { loadReminders, loadWeekState } from "@/lib/reminders";
import { daysBetween, fmtYMD, riyadhDate, subscriptionState } from "@/lib/schedule";

type Alert = { order_no: string; name: string; text: string; tone: "warn" | "info" | "bad" };

export default async function AdminHome() {
  const coach = await requireCoach();
  const [data, s] = await Promise.all([
    withUser(coach.id, async (tx) => {
      const counts = (await tx.query("SELECT status, count(*)::int n FROM orders WHERE NOT is_demo GROUP BY status")).rows as { status: string; n: number }[];
      const newWeek = (await tx.query("SELECT count(*)::int n FROM orders WHERE NOT is_demo AND created_at > now() - interval '7 days'")).rows[0].n as number;
      const pendingReviews = (await tx.query("SELECT count(*)::int n FROM reviews WHERE status = 'pending'")).rows[0].n as number;
      const pendingCheckins = (await tx.query("SELECT count(*)::int n FROM check_ins WHERE coach_reply IS NULL")).rows[0].n as number;
      const latest = (await tx.query("SELECT order_no, product_name, offer_label, status, category, amount_due_halalas, contact_name, created_at FROM orders ORDER BY created_at DESC LIMIT 8")).rows;
      const demo = (await tx.query("SELECT (SELECT count(*) FROM products WHERE is_demo)::int + (SELECT count(*) FROM orders WHERE is_demo)::int AS n")).rows[0].n as number;

      // تنبيهات داخلية للمدربة (لا تُرسل لأحد): قرب انتهاء الاشتراك، مراجعات قريبة أو فائتة، قياسات ناقصة
      const today = riyadhDate();
      const r = await loadReminders(tx);
      const soon = Math.max(0, ...r.sub_expiry_days);
      const alerts: Alert[] = [];
      const { rows: subs } = await tx.query(
        `SELECT id, order_no, user_id, contact_name, product_name, status, sub_start_at, sub_end_at, review_weekday
           FROM orders WHERE status = 'active' AND category = 'follow' AND sub_start_at IS NOT NULL AND NOT is_demo AND archived_at IS NULL
          ORDER BY sub_end_at`);
      for (const o of subs) {
        if (subscriptionState(o, soon, today) === "ending_soon") {
          const left = daysBetween(today, riyadhDate(o.sub_end_at));
          alerts.push({ order_no: o.order_no, name: o.contact_name, tone: "warn", text: `الاشتراك ينتهي ${fmtYMD(riyadhDate(o.sub_end_at))} (متبقٍ ${left} يوم)` });
        }
        const weeks = await loadWeekState(tx, o, r, today);
        const next = weeks.find((w) => w.status !== "done" && w.windowEnd >= today);
        if (next && daysBetween(today, next.windowStart) <= r.review_lead_days) {
          alerts.push({ order_no: o.order_no, name: o.contact_name, tone: "info",
            text: `مراجعة الأسبوع ${next.no}: مفتوحة من ${fmtYMD(next.windowStart)} إلى ${fmtYMD(next.windowEnd)}` });
        }
        const missed = weeks.filter((w) => w.status === "missed").pop();
        if (missed && daysBetween(missed.windowEnd, today) <= 7) {
          alerts.push({ order_no: o.order_no, name: o.contact_name, tone: "bad", text: `لم تصل مراجعة الأسبوع ${missed.no} (انتهت نافذتها ${fmtYMD(missed.windowEnd)})` });
        }
      }
      const { rows: noMeasure } = await tx.query(
        `SELECT o.order_no, o.contact_name FROM orders o JOIN intakes i ON i.order_id = o.id
          WHERE NOT o.is_demo AND o.archived_at IS NULL AND o.status NOT IN ('cancelled','completed')
            AND (coalesce(i.health->>'weight','') = '' OR coalesce(i.health->>'height','') = '')
          ORDER BY o.created_at DESC LIMIT 20`);
      for (const o of noMeasure) alerts.push({ order_no: o.order_no, name: o.contact_name, tone: "warn", text: "الوزن أو الطول غير موجود في الاستبيان" });
      return { counts, newWeek, pendingReviews, pendingCheckins, latest, demo, alerts };
    }),
    getSettings(),
  ]);
  const c = (st: string) => data.counts.find((x) => x.status === st)?.n ?? 0;
  const setup = [
    { ok: mailConfigured(), label: "البريد (رمز الدخول والتنبيهات)", hint: "يحتاج RESEND_API_KEY و MAIL_FROM. بدونه لا يستطيع العملاء الدخول في الإنتاج." },
    { ok: process.env.STORAGE_DRIVER === "netlify", label: "التخزين الخاص للملفات (Netlify Blobs)", hint: "على جهاز التطوير يُستخدم مجلد محلي." },
    { ok: Boolean(process.env.COACH_NOTIFY_EMAIL), label: "بريد تنبيهات الطلبات للمدربة", hint: "COACH_NOTIFY_EMAIL" },
    { ok: Boolean(youtubeId(s.intro_video?.url)), label: "مقطع التعريف (YouTube Shorts)", hint: "أضيفيه من «المحتوى والإعدادات». القسم مخفي حتى إضافته." },
    { ok: whatsappConfigured(), label: "إشعارات واتساب (WhatsApp Business API)", hint: "غير مفعّلة حتى ضبط WHATSAPP_TOKEN و WHATSAPP_PHONE_NUMBER_ID و WHATSAPP_TEMPLATE_NAME. تُسجَّل المحاولات «لم يُرسل» حتى ذلك." },
    { ok: Boolean(process.env.CRON_SECRET), label: "التذكيرات التلقائية (كل ساعة)", hint: "تحتاج CRON_SECRET في Netlify. بدونه لا تعمل التذكيرات المجدولة، ويبقى الإرسال اليدوي متاحاً." },
    { ok: false, label: "بوابة الدفع الإلكتروني", hint: "غير مفعّلة. الدفع الحالي: تحويل بنكي مع مراجعتك." },
  ];

  return (
    <div className="stack" style={{ ["--space" as string]: "22px" }}>
      <h1>أهلاً {coach.name.split(" ")[0]}</h1>
      {data.demo > 0 && <p className="alert warn">توجد بيانات تجريبية ({data.demo}) في قاعدة البيانات. لا تُنشر في الإنتاج — احذفيها قبل الإطلاق.</p>}
      <div className="grid g4">
        <Link href="/admin/orders?status=awaiting_payment" className="card stat" style={{ textDecoration: "none", color: "inherit" }} data-testid="stat-new-orders"><span className="muted">طلبات جديدة بانتظار الدفع</span><b>{c("awaiting_payment")}</b><span className="small muted">{data.newWeek} طلب خلال آخر 7 أيام</span></Link>
        <Link href="/admin/orders?status=payment_review" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">إيصالات بانتظار التحقق</span><b>{c("payment_review")}</b></Link>
        <Link href="/admin/orders?status=awaiting_quote" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">بانتظار تأكيد المبلغ</span><b>{c("awaiting_quote")}</b></Link>
        <Link href="/admin/orders?status=preparing" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">قيد الإعداد</span><b>{c("preparing")}</b></Link>
        <Link href="/admin/reviews" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">تقييمات بانتظار المراجعة</span><b>{data.pendingReviews}</b></Link>
      </div>
      <section className="card" aria-labelledby="alerts-h" data-testid="coach-alerts">
        <h2 id="alerts-h" style={{ fontSize: 18, marginBottom: 12 }}>تنبيهات المتابعة <span className="small muted">(داخلية — لا تُرسل للمتدربين)</span></h2>
        {data.alerts.length === 0 ? <p className="muted">لا توجد تنبيهات حالياً.</p> : (
          <ul className="alert-list">
            {data.alerts.map((a, i) => (
              <li key={i} className={a.tone}>
                <Link href={`/admin/orders/${a.order_no}`}><bdi className="num">{a.order_no}</bdi></Link> · {a.name} — {a.text}
              </li>
            ))}
          </ul>
        )}
      </section>
      <div className="grid g2" style={{ alignItems: "start" }}>
        <div className="card">
          <h2 style={{ fontSize: 18, marginBottom: 12 }}>أحدث الطلبات</h2>
          {data.latest.length === 0 ? <p className="muted">لا توجد طلبات بعد.</p> : (
            <ul style={{ listStyle: "none", padding: 0, margin: 0 }} className="stack">
              {data.latest.map((o) => (
                <li key={o.order_no} className="row" style={{ justifyContent: "space-between" }}>
                  <Link href={`/admin/orders/${o.order_no}`}><bdi className="num">{o.order_no}</bdi></Link>
                  <span className="small">{o.contact_name} · {o.product_name} · {riyals(o.amount_due_halalas)} · {fmtDate(o.created_at)}</span>
                  <span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span>
                </li>
              ))}
            </ul>
          )}
          <p className="small" style={{ marginTop: 12 }}>مراجعات أسبوعية بدون رد: <Link href="/admin/orders?status=active">{data.pendingCheckins}</Link></p>
        </div>
        <div className="card">
          <h2 style={{ fontSize: 18, marginBottom: 12 }}>حالة الإعداد</h2>
          <ul className="checklist">
            {setup.map((x) => <li key={x.label} className={x.ok ? "" : "no"}><b>{x.label}</b> — {x.ok ? "مفعّل" : "غير مفعّل"}<br /><span className="small muted">{x.hint}</span></li>)}
          </ul>
        </div>
      </div>
    </div>
  );
}
