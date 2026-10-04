import Link from "next/link";
import LineChart from "@/components/LineChart";
import StartTag from "@/components/admin/StartTag";
import { batch, litList, withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { mailConfigured } from "@/lib/mail";
import { riyals } from "@/lib/format";
import { statusLabel, statusTone } from "@/lib/status";
import { getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";
import { whatsappConfigured } from "@/lib/notify";
import { loadReminders, loadWeekState } from "@/lib/reminders";
import { daysBetween, fmtYMD, riyadhDate, subscriptionState } from "@/lib/schedule";
import { loadRenewals } from "@/lib/renewal";
import { loadAdherence } from "@/lib/program-data";
import { prefetchOrders } from "@/lib/order-prefetch";
import { pct } from "@/lib/adherence";
import ActionForm from "@/components/admin/ActionForm";
import { grantRewardAction } from "@/app/actions/admin";
import GrantedAlert from "@/components/admin/GrantedAlert";
import { autoFillTargets, loadPendingAuto, loadPendingSuggestions } from "@/lib/calorie-data";

type Alert = { order_no: string; name: string; text: string; tone: "warn" | "info" | "bad" };
type Todo = { order_no: string; name: string; text: string; href: string; tone: "warn" | "info" | "bad"; grant?: boolean };
type Ending = { order_no: string; name: string; product: string; end: string; left: number; renewal: string; tone: "warn" | "bad" | "ok" };

// الطلبات التي تنتظر إجراء منكِ أولاً، ثم التي تنتظر المتدرب
const INCOMPLETE = ["payment_review", "awaiting_quote", "preparing", "awaiting_payment"];
const ago = (iso: string, today: string) => {
  const d = daysBetween(riyadhDate(iso), today);
  return d <= 0 ? "اليوم" : d === 1 ? "منذ يوم" : d === 2 ? "منذ يومين" : `منذ ${d} أيام`;
};

export default async function AdminHome({ searchParams }: { searchParams: Promise<{ granted?: string; sent?: string }> }) {
  const sp = await searchParams;
  const coach = await requireCoach();
  const [data, s] = await Promise.all([
    withUser(coach.id, async (tx) => {
      // الاشتراكات التي مرّ يوم انتهائها تصبح «انتهى الاشتراك» (احتياط إن لم تعمل التذكيرات المجدولة)
      // كل استعلام في رحلة شبكة مستقلة إلى قاعدة البيانات، فنجمع المستقل منها في رحلة واحدة (batch)
      const [, countsR, newWeekR, pendingReviewsR, swapsR, incompleteR, demoR, monthlyR] = await batch(tx, [
        "SELECT app.expire_subscriptions()",
        "SELECT status, count(*)::int n FROM orders WHERE NOT is_demo GROUP BY status",
        "SELECT count(*)::int n FROM orders WHERE NOT is_demo AND created_at > now() - interval '7 days'",
        "SELECT count(*)::int n FROM reviews WHERE status = 'pending'",
        "SELECT count(DISTINCT user_id)::int n FROM exercise_swaps WHERE seen_at IS NULL",
        `SELECT order_no, product_name, status, category, amount_due_halalas, contact_name, created_at, renewal_kind, preferred_start::text FROM orders
          WHERE NOT is_demo AND archived_at IS NULL AND status = ANY(${litList(tx, INCOMPLETE, "text")})
          ORDER BY array_position(${litList(tx, INCOMPLETE, "text")}, status), preferred_start NULLS FIRST, created_at LIMIT 40`,
        "SELECT (SELECT count(*) FROM products WHERE is_demo)::int + (SELECT count(*) FROM orders WHERE is_demo)::int AS n",
        // آخر 6 أشهر (بتوقيت الرياض): عدد الطلبات، الأعضاء الجدد، ومجموع المبالغ المدفوعة (طلبات مؤكدة الدفع، بدون المجاني والتجريبي)
        `SELECT to_char(m, 'YYYY-MM') AS ym,
                (SELECT count(*)::int FROM orders o WHERE NOT o.is_demo AND NOT o.is_free AND date_trunc('month', o.created_at AT TIME ZONE 'Asia/Riyadh') = m) AS orders,
                (SELECT count(*)::int FROM "user" u WHERE u.role = 'client' AND date_trunc('month', u."createdAt" AT TIME ZONE 'Asia/Riyadh') = m) AS members,
                (SELECT coalesce(sum(o.amount_due_halalas), 0)::bigint FROM orders o WHERE NOT o.is_demo AND NOT o.is_free AND o.paid_at IS NOT NULL AND o.status <> 'cancelled'
                    AND date_trunc('month', o.paid_at AT TIME ZONE 'Asia/Riyadh') = m) AS revenue
           FROM generate_series(date_trunc('month', now() AT TIME ZONE 'Asia/Riyadh') - interval '5 months', date_trunc('month', now() AT TIME ZONE 'Asia/Riyadh'), interval '1 month') m ORDER BY m`,
      ]);
      const monthly = (monthlyR.rows as { ym: string; orders: number; members: number; revenue: string }[]).map((r) => ({ ym: r.ym, orders: r.orders, members: r.members, revenue: Number(r.revenue) / 100 }));
      const counts = countsR.rows as { status: string; n: number }[];
      const newWeek = newWeekR.rows[0].n as number;
      const pendingReviews = pendingReviewsR.rows[0].n as number;
      const swaps = swapsR.rows[0].n as number;
      const incomplete = incompleteR.rows;
      const demo = demoR.rows[0].n as number;

      // تنبيهات داخلية للمدربة (لا تُرسل لأحد): قرب انتهاء الاشتراك، مراجعات قريبة أو فائتة، قياسات ناقصة
      const today = riyadhDate();
      const r = await loadReminders(tx);
      const soon = Math.max(0, ...r.sub_expiry_days);
      const alerts: Alert[] = [];
      const todos: Todo[] = [];
      const ending: Ending[] = [];
      const [subsR, checkInsR, surveysR, swapTodoR, noProgramR, noMeasureR] = await batch(tx, [
        `SELECT id, order_no, user_id, contact_name, product_name, status, category, months, offer_id, list_price_halalas, renewal_kind,
                sub_start_at, sub_end_at, review_weekday
           FROM orders WHERE status = 'active' AND category = 'follow' AND sub_start_at IS NOT NULL AND NOT is_demo AND archived_at IS NULL
          ORDER BY sub_end_at`,
        `SELECT o.order_no, o.contact_name, count(*)::int n FROM check_ins c JOIN orders o ON o.id = c.order_id
          WHERE c.replied_at IS NULL AND NOT o.is_demo GROUP BY 1, 2 ORDER BY min(c.created_at)`,
        `SELECT o.order_no, o.contact_name, s.wants_renewal FROM exit_surveys s JOIN orders o ON o.id = s.order_id
          WHERE s.seen_at IS NULL AND NOT o.is_demo ORDER BY s.created_at`,
        `SELECT o.order_no, o.contact_name, count(*)::int n FROM exercise_swaps s JOIN blocks b ON b.id = s.block_id JOIN orders o ON o.id = b.order_id
          WHERE s.seen_at IS NULL AND NOT o.is_demo GROUP BY 1, 2 ORDER BY min(s.created_at)`,
        `SELECT o.order_no, o.contact_name, b.start_date::text AS start_date, b.weeks FROM orders o
           LEFT JOIN blocks b ON b.order_id = o.id AND b.status = 'active'
          WHERE o.status = 'active' AND o.category = 'follow' AND NOT o.is_demo AND o.archived_at IS NULL
            AND (o.sub_start_at IS NULL OR o.sub_start_at <= now() + interval '3 days')
            AND (b.id IS NULL OR b.start_date + b.weeks * 7 <= current_date + 3)
          ORDER BY o.sub_start_at NULLS FIRST`,
        `SELECT o.order_no, o.contact_name FROM orders o JOIN intakes i ON i.order_id = o.id
          WHERE NOT o.is_demo AND o.archived_at IS NULL AND o.status NOT IN ('cancelled','completed')
            AND (coalesce(i.health->>'weight','') = '' OR coalesce(i.health->>'height','') = '')
          ORDER BY o.created_at DESC LIMIT 20`,
      ]);
      const subs = subsR.rows, noMeasure = noMeasureR.rows;
      const renewals = await loadRenewals(tx, subs, (o) => daysBetween(today, riyadhDate(o.sub_end_at)));
      // بيانات الالتزام والمراجعات لكل المشتركين دفعة واحدة (بدل 6 استعلامات لكل متدرب)
      await prefetchOrders(tx, subs.map((o) => o.id as string));

      // (ب) ما يحتاج تعديلاً منكِ
      for (const x of checkInsR.rows) {
        todos.push({ order_no: x.order_no, name: x.contact_name, tone: "warn", href: `/admin/orders/${x.order_no}`,
          text: x.n === 1 ? "مراجعة أسبوعية بدون رد" : `${x.n} مراجعات أسبوعية بدون رد` });
      }
      for (const x of surveysR.rows) {
        todos.push({ order_no: x.order_no, name: x.contact_name, tone: x.wants_renewal ? "info" : "warn", href: `/admin/orders/${x.order_no}`,
          text: `ردّ على استبيان نهاية البرنامج — ${x.wants_renewal ? "يرغب بالتجديد" : "لا يرغب بالتجديد"}` });
      }
      for (const x of swapTodoR.rows) {
        todos.push({ order_no: x.order_no, name: x.contact_name, tone: "info", href: `/admin/orders/${x.order_no}/program`,
          text: x.n === 1 ? "بدّل تمريناً — راجعي التبديل" : `بدّل ${x.n} تمارين — راجعي التبديلات` });
      }
      for (const x of noProgramR.rows) {
        const endsOn = x.start_date ? fmtYMD(new Date(Date.parse(`${x.start_date}T00:00:00Z`) + (x.weeks * 7 - 1) * 86_400_000).toISOString().slice(0, 10)) : null;
        todos.push({ order_no: x.order_no, name: x.contact_name, tone: "bad", href: `/admin/orders/${x.order_no}/program`,
          text: endsOn ? `برنامج التمرين الحالي ينتهي ${endsOn} — جهّزي البرنامج التالي` : "لا يوجد برنامج تمرين مُسند" });
      }

      for (const o of subs) {
        // (ج) اشتراكات قربت تنتهي
        const state = subscriptionState(o, soon, today);
        if (state === "ending_soon" || state === "expired") {
          const left = daysBetween(today, riyadhDate(o.sub_end_at));
          const rn = renewals.get(o.id);
          ending.push({ order_no: o.order_no, name: o.contact_name, product: o.product_name, end: fmtYMD(riyadhDate(o.sub_end_at)), left,
            renewal: rn?.kind === "renewed" ? (rn.reward ? "🎁 مكافأة مفعّلة" : "✓ جدّد")
              : rn?.kind === "pending" ? (rn.status === "awaiting_payment" ? "طلب التجديد بانتظار الدفع" : "إيصال التجديد بانتظار التحقق")
              : rn?.kind === "offer" ? "عرض الخصم ظاهر له — لم يجدد بعد" : "لم يجدد بعد",
            tone: rn?.kind === "renewed" ? "ok" : left < 0 ? "bad" : "warn" });
        }
        // مستحقو مكافأة الالتزام
        if (o.months >= 3 && o.renewal_kind !== "reward") {
          const a = await loadAdherence(tx, o, r.review_window_days, today);
          if (a?.eligible && !a.rewarded) {
            todos.unshift({ order_no: o.order_no, name: o.contact_name, tone: "info", href: `/admin/orders/${o.order_no}`, grant: true,
              text: `🎉 التزام ${pct(a.avg)} خلال ${a.scored} أسبوعاً — مستحق 3 أشهر مجاناً` });
          }
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
      // سعرات محسوبة تلقائياً تنتظر تأكيد الحسبة
      await autoFillTargets(tx);
      for (const a of await loadPendingAuto(tx)) {
        todos.push({ order_no: a.order_no, name: a.name, tone: "warn", href: `/admin/orders/${a.order_no}/nutrition`,
          text: `⏳ سعرات محسوبة تلقائياً بانتظار تأكيدك: ${Number(a.kcal).toLocaleString("en-US")}` });
      }
      // سعرات مقترحة جديدة من بيانات المتدرب (وزن/نشاط) تنتظر اعتمادك
      for (const sg of await loadPendingSuggestions(tx)) {
        todos.push({ order_no: sg.order_no, name: sg.name, tone: "info", href: `/admin/orders/${sg.order_no}/nutrition`,
          text: `🔥 سعرات مقترحة جديدة: ${sg.kcal.toLocaleString("en-US")} (${sg.diff > 0 ? "+" : ""}${sg.diff})` });
      }
      for (const o of noMeasure) alerts.push({ order_no: o.order_no, name: o.contact_name, tone: "warn", text: "الوزن أو الطول غير موجود في الاستبيان" });
      return { monthly, swaps, counts, newWeek, pendingReviews, incomplete, todos, ending, demo, alerts, today };
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
      {sp.granted && <GrantedAlert no={sp.granted} sent={sp.sent === "1"} />}
      {data.demo > 0 && <p className="alert warn">توجد بيانات تجريبية ({data.demo}) في قاعدة البيانات. لا تُنشر في الإنتاج — احذفيها قبل الإطلاق.</p>}
      <section className="stack" style={{ ["--space" as string]: "10px" }} aria-labelledby="stats-h" data-testid="monthly-stats">
        <h2 id="stats-h" style={{ fontSize: 20 }}>الأرقام الشهرية (آخر 6 أشهر)</h2>
        <div className="grid g3">
          {([["orders", "عدد الطلبات", "", "var(--navy)"], ["members", "عدد الأعضاء الجدد", "", "var(--cyan)"], ["revenue", "مجموع المبالغ المدفوعة", " ريال", "#c77d00"]] as const).map(([k, title, unit, color]) => {
            const total = data.monthly.reduce((a, m) => a + m[k], 0);
            return (
              <div key={k} className="card stack" style={{ ["--space" as string]: "6px" }}>
                <span className="muted">{title}</span>
                <b className="num" style={{ fontSize: 24 }}>{total.toLocaleString("en-US")}{unit}</b>
                <LineChart title={title} unit={unit} height={160} series={[{ label: title, color, points: data.monthly.map((m) => ({ x: m.ym.slice(2), y: m[k] })) }]} />
              </div>
            );
          })}
        </div>
        <p className="small muted">الطلبات بدون المجانية والتجريبية. المبالغ لطلبات تأكد دفعها (حسب شهر الدفع)، بدون الملغاة والمجانية.</p>
      </section>
      <div className="grid g4">
        <Link href="/admin/orders?status=awaiting_payment" className="card stat" style={{ textDecoration: "none", color: "inherit" }} data-testid="stat-new-orders"><span className="muted">طلبات جديدة بانتظار الدفع</span><b>{c("awaiting_payment")}</b><span className="small muted">{data.newWeek} طلب خلال آخر 7 أيام</span></Link>
        <Link href="/admin/orders?status=payment_review" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">إيصالات بانتظار التحقق</span><b>{c("payment_review")}</b></Link>
        <Link href="/admin/orders?status=awaiting_quote" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">بانتظار تأكيد المبلغ</span><b>{c("awaiting_quote")}</b></Link>
        <Link href="/admin/orders?status=preparing" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">قيد الإعداد</span><b>{c("preparing")}</b></Link>
        <Link href="/admin/reviews" className="card stat" style={{ textDecoration: "none", color: "inherit" }}><span className="muted">تقييمات بانتظار المراجعة</span><b>{data.pendingReviews}</b></Link>
        <Link href="/admin/members?view=swaps" className="card stat" style={{ textDecoration: "none", color: "inherit" }} data-testid="stat-swaps"><span className="muted">متدربون بدّلوا تمارين</span><b>{data.swaps}</b><span className="small muted">لم تطّلعي عليها بعد</span></Link>
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
      <div className="grid g3 dash-lists" style={{ alignItems: "start" }}>
        <section className="card" aria-labelledby="inc-h" data-testid="dash-incomplete">
          <h2 id="inc-h" style={{ fontSize: 18, marginBottom: 12 }}>طلبات تحتاج إكمال <span className="count">{data.incomplete.length}</span></h2>
          {data.incomplete.length === 0 ? <p className="muted">لا توجد طلبات معلّقة.</p> : (
            <ul className="dash-list">
              {data.incomplete.map((o) => (
                <li key={o.order_no}>
                  <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
                    <Link href={`/admin/orders/${o.order_no}`}><b>{o.contact_name}</b></Link>
                    <span className={`status ${statusTone(o.status)}`}>{statusLabel(o.status, o.category)}</span>
                  </div>
                  <StartTag status={o.status} pref={o.preferred_start} today={data.today} />
                  <span className="small muted">
                    {o.renewal_kind === "renewal" ? "🔁 تجديد · " : ""}{o.product_name} · {riyals(o.amount_due_halalas)} · {ago(o.created_at, data.today)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
        <section className="card" aria-labelledby="todo-h" data-testid="dash-todos">
          <h2 id="todo-h" style={{ fontSize: 18, marginBottom: 12 }}>تحتاج تعديل منكِ <span className="count">{data.todos.length}</span></h2>
          {data.todos.length === 0 ? <p className="muted">لا شيء بانتظارك الآن 👌</p> : (
            <ul className="dash-list">
              {data.todos.map((t, i) => (
                <li key={i} className={t.tone} data-testid={t.grant ? "reward-eligible" : undefined}>
                  <Link href={t.href}><b>{t.name}</b></Link>
                  <span className="small">{t.text}</span>
                  {t.grant && (
                    <ActionForm action={grantRewardAction} className="form" submit="منح 3 أشهر مجاناً" submitClass="btn btn-sm"
                      confirm={`منح ${t.name} اشتراكاً مجانياً لـ 3 أشهر يبدأ بعد نهاية اشتراكه الحالي؟`}>
                      <input type="hidden" name="order_no" value={t.order_no} />
                      <input type="hidden" name="back" value="/admin" />
                    </ActionForm>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
        <section className="card" aria-labelledby="end-h" data-testid="dash-ending">
          <h2 id="end-h" style={{ fontSize: 18, marginBottom: 12 }}>اشتراكات قربت تنتهي <span className="count">{data.ending.length}</span></h2>
          {data.ending.length === 0 ? <p className="muted">لا توجد اشتراكات تنتهي قريباً.</p> : (
            <ul className="dash-list">
              {data.ending.map((e) => (
                <li key={e.order_no} className={e.tone === "ok" ? "" : e.tone}>
                  <div className="row" style={{ justifyContent: "space-between", gap: 8 }}>
                    <Link href={`/admin/orders/${e.order_no}`}><b>{e.name}</b></Link>
                    <span className="small num">{e.left < 0 ? `انتهى منذ ${-e.left} يوم` : e.left === 0 ? "ينتهي اليوم" : e.left === 1 ? "باقي يوم" : e.left === 2 ? "باقي يومين" : `باقي ${e.left} أيام`}</span>
                  </div>
                  <span className="small muted">{e.product} · {e.end}</span>
                  <span className={`small ${e.tone === "ok" ? "ok-text" : ""}`}>{e.renewal}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
      <div className="grid g2" style={{ alignItems: "start" }}>
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
