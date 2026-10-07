import { getCurrentUser } from "@/lib/session";
import { getOrderDetail, getSettings } from "@/lib/data";
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
    review: entitled ? (d.review ? { status: d.review.status, body: d.review.body, rating: d.review.rating, consent: d.review.consent_publish, reply: d.review.coach_reply } : { status: "none" }) : null,
  }, { headers: { "Cache-Control": "private, no-store" } });
}
