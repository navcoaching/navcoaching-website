import type { PublicReview } from "@/lib/data";
import { fmtDate } from "@/lib/format";
import type { Lang } from "@/lib/lang";
import { t } from "@/i18n/ui";
import ReviewText from "./ReviewText";

export default function ReviewCard({ r, lang = "ar" }: { r: PublicReview; lang?: Lang }) {
  const u = t(lang).reviews;
  return (
    <figure className="card review reveal">
      <div className="review-top">
        <span className="qmark" aria-hidden="true">”</span>
        {r.rating ? <span className="stars" role="img" aria-label={u.ratingAria(r.rating)}>{"★".repeat(r.rating)}</span> : null}
      </div>
      {/* نص التقييم يبقى بلغته الأصلية (عربي غالباً) */}
      <ReviewText body={r.body} />
      <figcaption className="who">
        <b>{r.display_name}</b>
        <span className="muted">{r.period_label ?? fmtDate(r.created_at, lang)}{r.product_name ? ` · ${r.product_name}` : ""}</span>
      </figcaption>
      <span className="verified">✓ {r.source === "platform" ? u.verifiedPlatform : u.verified}</span>
      {r.coach_reply && <p className="reply"><b>{u.reply}</b> {r.coach_reply}</p>}
    </figure>
  );
}
