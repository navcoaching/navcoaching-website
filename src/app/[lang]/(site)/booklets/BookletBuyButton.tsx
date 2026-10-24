"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { buyBookletAction, type BuyBookletState } from "@/app/actions/booklets";
import { Submit, useFormAction } from "@/components/FormBits";
import { OPT } from "@/lib/intake";
import { href } from "@/lib/lang";
import { useLang } from "@/lib/use-lang";
import { t } from "@/i18n/ui";

/**
 * زر شراء الكتيب حسب حالة المستخدم. الحماية الفعلية (الدخول، المعروض للبيع، السعر، عدم التكرار)
 * في الخادم وقاعدة البيانات، لا في هذا الزر.
 */
export default function BookletBuyButton({ id, price, loggedIn, owned, pendingOrder, phone }: {
  id: string; price: string; loggedIn: boolean; owned: boolean; pendingOrder: string | null; phone: { cc: string; national: string };
}) {
  const router = useRouter();
  const lang = useLang();
  const u = t(lang).booklets;
  const [open, setOpen] = useState(false);
  const [idem, setIdem] = useState("");
  useEffect(() => { setIdem(crypto.randomUUID()); }, []);
  const { state, onSubmit, pending } = useFormAction(buyBookletAction as (s: BuyBookletState, fd: FormData) => Promise<BuyBookletState>);
  const s = state as BuyBookletState;
  useEffect(() => { if (s.ok && s.orderNo) router.push(`/account/orders/${s.orderNo}`); }, [s.ok, s.orderNo, router]);

  if (!loggedIn || s.needLogin) {
    return (
      <div className="stack" style={{ ["--space" as string]: "8px" }}>
        <Link className="btn btn-block" href={`/login?next=${encodeURIComponent(href(lang, "/booklets"))}`}>{u.buy}</Link>
        <span className="small muted">{u.needAccount}</span>
      </div>
    );
  }
  if (owned) return <Link className="btn btn-ghost btn-block" href="/account#booklets" data-testid="booklet-owned">{u.owned}</Link>;
  if (pendingOrder) {
    return (
      <div className="stack" style={{ ["--space" as string]: "8px" }} data-testid="booklet-pending">
        <Link className="btn btn-block" href={`/account/orders/${pendingOrder}`}>{u.completePay}</Link>
        <span className="small muted">{u.pendingNo} <bdi className="num">{pendingOrder}</bdi> {u.pendingWait}</span>
      </div>
    );
  }
  if (!open) return <button type="button" className="btn btn-block" onClick={() => setOpen(true)}>{u.buy}</button>;
  return (
    <form onSubmit={onSubmit} className="stack" style={{ ["--space" as string]: "10px" }} data-testid="booklet-buy-form">
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="idempotency_key" value={idem} />
      <div className="field">
        <label htmlFor={`bk-phone-${id}`}>{u.phone}</label>
        <div className="phone-row" dir="ltr">
          <select name="cc" aria-label={u.cc} defaultValue={phone.cc}>{OPT.cc.map((c) => <option key={c}>{c}</option>)}</select>
          <input id={`bk-phone-${id}`} name="phone" type="tel" inputMode="tel" autoComplete="tel-national" defaultValue={phone.national} required />
        </div>
      </div>
      {s.error && <p className="alert err" role="alert">{s.error}</p>}
      <Submit pending={pending || Boolean(s.ok)} className="btn btn-block" pendingText={u.creating}>{u.confirm} {price} {lang === "en" ? "SAR" : "ر.س"}</Submit>
      <span className="small muted">{u.next}</span>
    </form>
  );
}
