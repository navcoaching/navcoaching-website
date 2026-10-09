import { getCurrentUser } from "@/lib/session";
import { getMyFollowUp, getOrderDetail, getSettings } from "@/lib/data";
import { withUser } from "@/lib/db";
import { loadEndOfProgram } from "@/components/account/EndOfProgram";
import { PRE_ACTIVE } from "@/lib/status";
import { startPrefRange } from "@/lib/schedule";
import { riyals } from "@/lib/format";
import { statusLabel } from "@/lib/status";

export const dynamic = "force-dynamic";

const ENTITLED = ["active", "delivered", "completed"];

// تفاصيل طلب واحد للتطبيق (مثل صفحة الطلب في الموقع): الملفات، المراجعات الأسبوعية وردود المدربة، والتقييم
export async function GET(_: Request, { params }: { params: Promise<{ no: string }> }) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const { no } = await params;
  const [d, s] = await Promise.all([getOrderDetail(user.id, no), getSettings()]);
  if (!d || d.order.user_id !== user.id) return Response.json({ error: "not found" }, { status: 404 });
  const o = d.order;
  const entitled = ENTITLED.includes(o.status);
  const checkinsOn = o.category === "follow" && Boolean(s.checkins?.enabled);
  const [follow, end] = await Promise.all([
    getMyFollowUp(user.id, o),
    entitled ? withUser(user.id, (tx) => loadEndOfProgram(tx, [o])).then((m) => m.get(o.id) ?? null) : null,
  ]);
  const renewal = follow?.renewal ?? null;
  return Response.json({
    order: {
      order_no: o.order_no, product_name: o.product_name, offer_label: o.offer_label, status: o.status,
      status_label: statusLabel(o.status, o.category), category: o.category,
      amount: o.amount_due_halalas == null ? null : riyals(o.amount_due_halalas), created_at: o.created_at,
    },
    entitled,
    files: entitled ? d.deliverables.map((f) => ({ id: f.id, title: f.title, kind: f.kind, url: f.kind === "file" ? `/api/files/deliverable/${f.id}` : f.url, mime: f.mime })) : [],
    checkin: checkinsOn && (o.status === "active" || d.checkins.length > 0) ? {
      can_submit: o.status === "active",
      questions: o.status === "active" ? s.checkins.questions : [],
      history: d.checkins.map((c) => ({ id: c.id, created_at: c.created_at, answers: c.answers, reply: c.coach_reply, video: c.coach_video_url, replied_at: c.replied_at })),
    } : null,
    // موعد البداية (قبل التفعيل)، والتجديد بخصم (آخر أيام الاشتراك)، واستبيان نهاية البرنامج
    start: PRE_ACTIVE.includes(o.status) && !o.sub_start_at ? { pref: o.preferred_start ?? null, range: startPrefRange() } : null,
    renewal: renewal && renewal.kind === "offer" ? { kind: "offer", left: renewal.left, price: riyals(renewal.price), discounted: riyals(renewal.discounted) }
      : renewal ? { kind: renewal.kind, order_no: renewal.orderNo } : null,
    end_of_program: end ? { survey_done: Boolean(end.survey) } : null,
    review: entitled ? (d.review ? { status: d.review.status, body: d.review.body, rating: d.review.rating, consent: d.review.consent_publish, reply: d.review.coach_reply } : { status: "none" }) : null,
  }, { headers: { "Cache-Control": "private, no-store" } });
}
