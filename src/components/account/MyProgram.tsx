import Link from "next/link";
import { withUser } from "@/lib/db";
import { getSettings } from "@/lib/data";
import { DEFAULT_REMINDERS, daysBetween, fmtYMD, riyadhDate, subscriptionState } from "@/lib/schedule";
import { waLink } from "@/lib/format";
import { loadRenewals, type RenewalInfo } from "@/lib/renewal";
import { loadAdherence } from "@/lib/program-data";
import AdherenceBar from "./AdherenceBar";
import ProgramTodayView, { loadProgramToday, type ProgramToday } from "./ProgramToday";
import RenewalPopup, { RenewButton, RenewPrice } from "./RenewalPopup";

type O = {
  id: string; order_no: string; status: string; category: string; months: number; product_name: string; offer_label: string;
  offer_id?: string | null; list_price_halalas: number; review_weekday?: number | null; renewal_kind?: string | null;
  product_slug?: string | null; sub_start_at?: string | null; sub_end_at?: string | null;
};

/** تنبيه قرب انتهاء الباقة أو انتهائها (يُستخدم أعلى «حسابي» وصفحة الطلب) */
export function ExpiryAlert({ o, soonDays, whatsapp, renewal }: { o: O; soonDays: number; whatsapp: string; renewal?: RenewalInfo }) {
  if (!o.sub_start_at || !o.sub_end_at) return null;
  const today = riyadhDate();
  const end = riyadhDate(o.sub_end_at);
  const state = subscriptionState({ status: o.status, sub_start_at: o.sub_start_at, sub_end_at: o.sub_end_at }, soonDays, today);
  if (state !== "ending_soon" && state !== "expired") return null;
  const left = daysBetween(today, end);
  const renew = o.product_slug ? `/programs/${o.product_slug}` : "/programs";
  const wa = waLink(whatsapp, `مرحباً، أبي أجدد اشتراكي (${o.product_name}) — طلب رقم ${o.order_no}`);
  if (renewal?.kind === "renewed") {
    return (
      <div className="alert ok expiry-alert" role="status" data-testid="expiry-alert">
        <span>{renewal.reward ? "🎁 مكافأة التزامك (3 أشهر مجاناً) تبدأ بعد نهاية اشتراكك الحالي." : "✓ تم تجديد اشتراكك، ويبدأ بعد نهاية اشتراكك الحالي."}{" "}
          <Link href={`/account/orders/${renewal.orderNo}`}>التفاصيل</Link></span>
      </div>
    );
  }
  if (renewal?.kind === "pending") {
    return (
      <div className="alert info expiry-alert" role="status" data-testid="expiry-alert">
        <div className="stack" style={{ ["--space" as string]: "8px" }}>
          <b>{renewal.status === "awaiting_payment" ? "طلب التجديد بانتظار الدفع." : "طلب التجديد قيد التأكيد."}</b>
          <Link className="btn btn-sm" style={{ width: "fit-content" }} href={`/account/orders/${renewal.orderNo}`}>
            {renewal.status === "awaiting_payment" ? "ادفع وارفع الإيصال" : "تفاصيل طلب التجديد"}</Link>
        </div>
      </div>
    );
  }
  const offer = renewal?.kind === "offer" ? renewal : null;
  return (
    <div className={`alert ${state === "expired" ? "err" : "warn"} expiry-alert`} role="status" data-testid="expiry-alert">
      <div className="stack" style={{ ["--space" as string]: "8px" }}>
        <b>{state === "expired" ? `انتهى اشتراكك في ${o.product_name} بتاريخ ${fmtYMD(end)}.`
          : left === 0 ? `اشتراكك في ${o.product_name} ينتهي اليوم (${fmtYMD(end)}).`
          : `اشتراكك في ${o.product_name} ينتهي خلال ${left === 1 ? "يوم واحد" : left === 2 ? "يومين" : `${left} أيام`} (${fmtYMD(end)}).`}</b>
        {offer ? (
          <>
            <span className="small">جدّد الآن بخصم 10% من سعر الباقة للحفاظ على مستواك وتطورك: <RenewPrice price={offer.price} discounted={offer.discounted} /></span>
            <div className="row" style={{ gap: 8, alignItems: "flex-start" }}>
              <RenewButton orderNo={o.order_no} />
              <a className="btn btn-ghost btn-sm" href={wa} target="_blank" rel="noopener noreferrer">تواصل على واتساب</a>
            </div>
          </>
        ) : (
          <>
            <span className="small">{state === "expired" ? "جدّد الآن عشان تستمر المتابعة." : "قبل الانتهاء بـ 5 أيام يتاح لك التجديد بخصم 10% من سعر الباقة."}</span>
            <div className="row" style={{ gap: 8 }}>
              {state === "expired" && <Link className="btn btn-sm" href={renew}>تجديد الباقة</Link>}
              <a className="btn btn-ghost btn-sm" href={wa} target="_blank" rel="noopener noreferrer">تواصل على واتساب</a>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

/** «برنامجي» أعلى صفحة حسابي: الباقة الفعّالة، مدتها، وروابط التمرين والتغذية، وتنبيه الانتهاء */
export default async function MyProgram({ userId, orders }: { userId: string; orders: O[] }) {
  const current = orders.filter((o) => o.status === "active" || o.status === "delivered");
  if (!current.length) return null;
  const [info, s] = await Promise.all([
    withUser(userId, async (tx) => {
      const { rows: [{ r }] } = await tx.query("SELECT app.review_schedule() AS r");
      const ids = current.map((o) => o.id);
      const blocks = new Set((await tx.query(`SELECT DISTINCT order_id FROM blocks WHERE order_id = ANY($1::uuid[])`, [ids])).rows.map((x) => x.order_id));
      const nutrition = new Set((await tx.query(
        `SELECT order_id FROM nutrition_targets WHERE order_id = ANY($1::uuid[])
         UNION SELECT order_id FROM nutrition_plans WHERE order_id = ANY($1::uuid[]) AND NOT archived
         UNION SELECT order_id FROM supplement_routines WHERE order_id = ANY($1::uuid[]) AND NOT archived`, [ids])).rows.map((x) => x.order_id));
      const soon = Math.max(0, ...((r?.sub_expiry_days as number[] | undefined) ?? DEFAULT_REMINDERS.sub_expiry_days));
      const today = riyadhDate();
      const renewals = await loadRenewals(tx, current, (o) => (o.sub_end_at ? daysBetween(today, riyadhDate(o.sub_end_at)) : null));
      const adherence = new Map<string, Awaited<ReturnType<typeof loadAdherence>>>();
      for (const o of current) if (o.category === "follow") {
        adherence.set(o.id, await loadAdherence(tx, { ...o, sub_start_at: o.sub_start_at ?? null, sub_end_at: o.sub_end_at ?? null },
          Number(r?.review_window_days ?? DEFAULT_REMINDERS.review_window_days), today));
      }
      const todayPlan = new Map<string, ProgramToday>();
      for (const o of current) todayPlan.set(o.id, await loadProgramToday(tx, o.id, userId, today));
      return { blocks, nutrition, soon, renewals, adherence, todayPlan };
    }),
    getSettings(),
  ]);
  const today = riyadhDate();
  return (
    <section className="stack" style={{ ["--space" as string]: "12px" }} aria-labelledby="myprog-h" data-testid="my-program">
      <h2 id="myprog-h" style={{ fontSize: 22 }}>برنامجي</h2>
      {current.map((o) => {
        const end = o.sub_end_at ? riyadhDate(o.sub_end_at) : null;
        const start = o.sub_start_at ? riyadhDate(o.sub_start_at) : null;
        const left = end ? daysBetween(today, end) : null;
        const renewal = info.renewals.get(o.id) ?? null;
        const adherence = info.adherence.get(o.id);
        return (
          <div key={o.id} className="stack" style={{ ["--space" as string]: "10px" }}>
            {renewal?.kind === "offer" && (
              <RenewalPopup today={today} offer={{ orderNo: o.order_no, product: o.product_name, left: renewal.left, price: renewal.price, discounted: renewal.discounted }} />
            )}
            <ExpiryAlert o={o} soonDays={info.soon} whatsapp={s.contact.whatsapp} renewal={renewal} />
            <div className="card stack my-program" style={{ ["--space" as string]: "10px" }}>
              <div className="row" style={{ justifyContent: "space-between" }}>
                <b style={{ fontFamily: "var(--f-display)", fontSize: 19 }}>{o.product_name}</b>
                <span className="small muted">{o.offer_label}</span>
              </div>
              {start && start > today ? (
                <p className="small" style={{ margin: 0 }}>يبدأ الاشتراك: <b>{fmtYMD(start)}</b>{end && <span className="muted"> · ينتهي {fmtYMD(end)}</span>}</p>
              ) : end && (
                <p className="small" style={{ margin: 0 }}>
                  ينتهي الاشتراك: <b>{fmtYMD(end)}</b>{left != null && left >= 0 && <span className="muted"> · متبقي {left === 1 ? "يوم واحد" : left === 2 ? "يومان" : left <= 10 ? `${left} أيام` : `${left} يوماً`}</span>}
                </p>
              )}
              {adherence && (!start || start <= today) && <AdherenceBar a={adherence} />}
              {(!start || start <= today) && info.todayPlan.get(o.id) && <ProgramTodayView orderNo={o.order_no} p={info.todayPlan.get(o.id)!} />}
              <div className="row my-program-links" style={{ gap: 8 }}>
                {info.blocks.has(o.id) && <Link className="btn btn-sm" href={`/account/orders/${o.order_no}/training`}>🏋️ برنامج التمرين</Link>}
                {info.nutrition.has(o.id) && <Link className="btn btn-sm" href={`/account/orders/${o.order_no}/nutrition`}>🥗 التغذية والمكملات</Link>}
                <Link className="btn btn-ghost btn-sm" href={`/account/orders/${o.order_no}`}>تفاصيل الطلب والمراجعات</Link>
              </div>
            </div>
          </div>
        );
      })}
    </section>
  );
}
