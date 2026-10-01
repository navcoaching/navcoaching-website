import Link from "next/link";
import { withUser, type Tx } from "@/lib/db";
import { riyadhDate } from "@/lib/schedule";
import { ExitSurveyForm, ReviewForm } from "@/app/(site)/account/ClientForms";

type O = { id: string; order_no: string; status: string; category: string; months: number; product_name: string; sub_end_at?: string | null };
export type ExitSurvey = { wants_renewal: boolean; reason: string; experience: string; created_at: string };
type Review = { status: string; body: string; consent_publish: boolean; created_at: string };

const REVIEW_STATUS: Record<string, string> = { pending: "قيد المراجعة", published: "منشور", rejected: "لم يُنشر", hidden: "مخفي" };

/** انتهى البرنامج: اشتراك متابعة أُنهي، أو وصل يوم انتهائه (بتوقيت الرياض) */
export function programEnded(o: O, today = riyadhDate()) {
  if (o.category !== "follow" || o.months <= 0) return false;
  if (o.status === "completed") return true;
  return ["active", "delivered"].includes(o.status) && !!o.sub_end_at && riyadhDate(o.sub_end_at) <= today;
}

/** الاستبيان والتقييم لكل اشتراك انتهى ولم يُجدَّد (التجديد أو المكافأة يعني أن الرحلة مستمرة) */
export async function loadEndOfProgram(tx: Tx, orders: O[]) {
  const ended = orders.filter((o) => programEnded(o));
  const out = new Map<string, { survey: ExitSurvey | null; review: Review | null }>();
  if (!ended.length) return out;
  const ids = ended.map((o) => o.id);
  const continued = new Set((await tx.query(
    `SELECT renewal_of FROM orders WHERE renewal_of = ANY($1::uuid[]) AND status <> 'cancelled'`, [ids])).rows.map((r) => r.renewal_of));
  const surveys = new Map((await tx.query(
    `SELECT order_id, wants_renewal, reason, experience, created_at FROM exit_surveys WHERE order_id = ANY($1::uuid[])`, [ids])).rows.map((r) => [r.order_id, r]));
  const reviews = new Map((await tx.query(
    `SELECT order_id, status, body, consent_publish, created_at FROM reviews WHERE order_id = ANY($1::uuid[])`, [ids])).rows.map((r) => [r.order_id, r]));
  for (const o of ended) {
    if (continued.has(o.id)) continue;
    out.set(o.id, { survey: surveys.get(o.id) ?? null, review: reviews.get(o.id) ?? null });
  }
  return out;
}

/** بطاقة نهاية البرنامج: سؤالان للمدربة، وتحتها خانة التقييم العام */
export function EndOfProgramCard({ orderNo, product, name, survey, review }: { orderNo: string; product: string; name: string; survey: ExitSurvey | null; review: Review | null }) {
  return (
    <section className="card stack end-program" aria-labelledby={`end-h-${orderNo}`} data-testid="exit-survey" style={{ ["--space" as string]: "14px" }}>
      <div className="stack" style={{ ["--space" as string]: "6px" }}>
        <h2 id={`end-h-${orderNo}`} style={{ fontSize: 21 }}>انتهى برنامجك 🌱</h2>
        <p className="small muted" style={{ margin: 0 }}>{product}</p>
      </div>
      <p style={{ margin: 0 }}>ولله الحمد انتهى البرنامج، لكن لم تنتهِ رحلتك في التطور النفسي والجسدي.</p>
      {survey ? (
        <p className="alert ok" role="status" style={{ margin: 0 }}>شكراً لك، وصلني ردك 🤍</p>
      ) : (
        <>
          <p style={{ margin: 0 }}>عندي لك بعض الأسئلة، ولا عليك أمر تجاوبها:</p>
          <ExitSurveyForm orderNo={orderNo} />
        </>
      )}
      <div className="stack end-review" style={{ ["--space" as string]: "10px" }} data-testid="exit-review">
        <h3 style={{ fontSize: 18 }}>قيّم تجربتك</h3>
        {review ? (
          <>
            <p className="alert ok" role="status" style={{ margin: 0 }}>شكراً لك! وصل تقييمك.</p>
            <p className="small muted" style={{ margin: 0 }}>حالة تقييمك: {REVIEW_STATUS[review.status] ?? review.status}{review.consent_publish ? "" : " (لم توافق على النشر، يظهر للمدربة فقط)"}</p>
            <blockquote style={{ margin: 0 }}>«{review.body}»</blockquote>
          </>
        ) : (
          <ReviewForm orderNo={orderNo} name={name} />
        )}
      </div>
      <Link className="small" href={`/account/orders/${orderNo}`}>تفاصيل الطلب</Link>
    </section>
  );
}

/** أعلى «حسابي»: البرامج المنتهية التي لم يكتمل استبيانها أو تقييمها */
export default async function EndOfProgramList({ userId, name, orders }: { userId: string; name: string; orders: O[] }) {
  const map = await withUser(userId, (tx) => loadEndOfProgram(tx, orders));
  // تبقى البطاقة يوماً بعد الإكمال حتى يرى المتدرب رسالة الشكر
  const recent = (iso: string) => Date.now() - new Date(iso).getTime() < 86_400_000;
  const open = orders.filter((o) => {
    const x = map.get(o.id);
    return x && (!x.survey || !x.review || recent(x.survey.created_at) || recent(x.review.created_at));
  });
  if (!open.length) return null;
  return (
    <>
      {open.map((o) => {
        const x = map.get(o.id)!;
        return <EndOfProgramCard key={o.id} orderNo={o.order_no} product={o.product_name} name={name} survey={x.survey} review={x.review} />;
      })}
    </>
  );
}
