import type { PublicReview } from "@/lib/data";
import { fmtDate } from "@/lib/format";

export default function ReviewCard({ r }: { r: PublicReview }) {
  return (
    <figure className="card review reveal">
      {r.rating ? <span className="stars" role="img" aria-label={`تقييم ${r.rating} من 5`}>{"★".repeat(r.rating)}</span> : null}
      <blockquote>«{r.body}»</blockquote>
      <figcaption className="who">
        <b>{r.display_name}</b>
        <span className="muted">{r.period_label ?? fmtDate(r.created_at)}{r.product_name ? ` · ${r.product_name}` : ""}</span>
      </figcaption>
      <span className="verified">✓ {r.source === "platform" ? "تقييم من متدرب اشترى الخدمة عبر الموقع" : "تقييم موثّق من متدرب اشترى الخدمة"}</span>
      {r.coach_reply && <p className="reply"><b>رد المدربة:</b> {r.coach_reply}</p>}
    </figure>
  );
}
