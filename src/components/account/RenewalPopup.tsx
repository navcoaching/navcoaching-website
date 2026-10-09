"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { renewAction } from "@/app/actions/client";
import { FormMessage, Submit, useFormAction } from "@/components/FormBits";
import { riyals } from "@/lib/format";

type Offer = { orderNo: string; product: string; left: number; price: number; discounted: number };

const leftText = (n: number) => (n === 0 ? "اليوم" : n === 1 ? "خلال يوم واحد" : n === 2 ? "خلال يومين" : `خلال ${n} أيام`);

/** زر «جدّد بخصم 10%»: ينشئ طلب التجديد وينقل المتدرب لصفحة الدفع */
export function RenewButton({ orderNo, className = "btn btn-sm" }: { orderNo: string; className?: string }) {
  const { state, onSubmit, pending } = useFormAction(renewAction);
  return (
    <form onSubmit={onSubmit} className="renew-form">
      <input type="hidden" name="order_no" value={orderNo} />
      <Submit className={className} pending={pending} pendingText="جارٍ إنشاء طلب التجديد…">جدّد بخصم 10%</Submit>
      <FormMessage state={state} />
    </form>
  );
}

/** السعر قبل الخصم وبعده */
export function RenewPrice({ price, discounted }: { price: number; discounted: number }) {
  return (
    <span className="renew-price">
      <s className="muted num">{riyals(price)}</s> <b className="num">{riyals(discounted)}</b>
    </span>
  );
}

/** نافذة منبثقة في آخر 5 أيام من الاشتراك (تُخفى لبقية اليوم عند «لاحقاً») */
export default function RenewalPopup({ offer, today }: { offer: Offer; today: string }) {
  const key = `renew-dismissed:${offer.orderNo}`;
  const [open, setOpen] = useState(false);
  useEffect(() => {
    let dismissed = false;
    try { dismissed = localStorage.getItem(key) === today; } catch { /* التخزين غير متاح */ }
    if (!dismissed) setOpen(true);
  }, [key, today]);
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") later(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const later = () => {
    try { localStorage.setItem(key, today); } catch { /* ignore */ }
    setOpen(false);
  };
  if (!open) return null;
  return (
    <div className="modal-backdrop" onClick={(e) => { if (e.target === e.currentTarget) later(); }}>
      <div className="modal card stack" role="dialog" aria-modal="true" aria-labelledby="renew-h" data-testid="renewal-popup" style={{ ["--space" as string]: "12px" }}>
        <h2 id="renew-h" style={{ fontSize: 21 }}>اشتراكك ينتهي {leftText(offer.left)} ⏳</h2>
        <p style={{ margin: 0 }}>
          إذا حاب تجدد اشتراكك في <b>{offer.product}</b>، لك خصم <b>10%</b> من سعر الباقة للحفاظ على مستواك وتطورك.
        </p>
        <RenewPrice price={offer.price} discounted={offer.discounted} />
        <p className="small muted" style={{ margin: 0 }}>
          يبدأ التجديد من نهاية اشتراكك الحالي، فما تخسر ولا يوم. بالتجديد توافق على <Link href="/policies#terms">الشروط والأحكام</Link>.
        </p>
        <div className="row" style={{ gap: 8, alignItems: "flex-start" }}>
          <RenewButton orderNo={offer.orderNo} className="btn" />
          <button type="button" className="btn btn-ghost" onClick={later}>لاحقاً</button>
        </div>
      </div>
    </div>
  );
}
