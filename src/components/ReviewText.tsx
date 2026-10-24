"use client";
import { useState } from "react";
import { useLang } from "@/lib/use-lang";
import { t } from "@/i18n/ui";

/** نص التقييم: الطويل يُختصر لعدة أسطر مع «المزيد» حتى تبقى البطاقات متناسقة */
export default function ReviewText({ body }: { body: string }) {
  const long = body.length > 230;
  const [open, setOpen] = useState(false);
  const u = t(useLang()).common;
  return (
    <div className="review-text">
      <blockquote className={long && !open ? "clamped" : undefined} dir="auto">{body}</blockquote>
      {long && (
        <button type="button" className="link-btn small" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
          {open ? u.less : u.more}
        </button>
      )}
    </div>
  );
}
