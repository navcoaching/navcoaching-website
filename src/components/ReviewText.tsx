"use client";
import { useState } from "react";

/** نص التقييم: الطويل يُختصر لعدة أسطر مع «اقرأ المزيد» حتى تبقى البطاقات متناسقة */
export default function ReviewText({ body }: { body: string }) {
  const long = body.length > 230;
  const [open, setOpen] = useState(false);
  return (
    <div className="review-text">
      <blockquote className={long && !open ? "clamped" : undefined}>{body}</blockquote>
      {long && (
        <button type="button" className="link-btn small" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
          {open ? "عرض أقل" : "اقرأ المزيد"}
        </button>
      )}
    </div>
  );
}
