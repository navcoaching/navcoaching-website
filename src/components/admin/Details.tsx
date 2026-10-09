"use client";
import { useState } from "react";

/** <details> يُفتح مبدئياً فقط، ولا يُغلق تلقائياً بعد تحديث الصفحة (حتى تبقى رسالة نتيجة الإجراء ظاهرة) */
export default function Details({ defaultOpen, className, children }: { defaultOpen: boolean; className?: string; children: React.ReactNode }) {
  const [open, setOpen] = useState(defaultOpen);
  return <details className={className} open={open} onToggle={(e) => setOpen(e.currentTarget.open)}>{children}</details>;
}
