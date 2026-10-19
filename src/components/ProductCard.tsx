import Link from "next/link";
import type { Product } from "@/lib/data";
import { CATEGORY_LABEL, riyals, shortName } from "@/lib/format";
import { IconArrow } from "./Icons";

export function fromPrice(p: Product) {
  const active = p.offers.filter((o) => o.active);
  if (!active.length) return null;
  // مثل الموقع الحالي: سعر الشهر الواحد إن وُجد، وإلا أقل سعر
  const monthly = active.find((o) => o.months === 1);
  if (monthly) {
    const longer = active.filter((o) => o.months > 1).sort((a, b) => a.months - b.months)[0];
    return { value: riyals(monthly.price_halalas), unit: "/ شهر", extra: longer ? `أو ${riyals(longer.price_halalas)} لـ ${longer.label}` : null };
  }
  const min = active.reduce((a, b) => (b.price_halalas < a.price_halalas ? b : a));
  return { value: riyals(min.price_halalas), unit: min.months === 0 ? "دفعة واحدة" : min.label, extra: null };
}

export default function ProductCard({ p, index = 0 }: { p: Product; index?: number }) {
  const price = fromPrice(p);
  return (
    <Link href={`/programs/${p.slug}`} className={`pcard reveal ${p.recommended ? "rec" : ""}`} style={{ ["--d" as string]: `${index * 70}ms` }}>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <span className="kicker">{CATEGORY_LABEL[p.category]}</span>
        {p.recommended && <span className="tag">الأكثر طلباً</span>}
        {p.is_demo && <span className="tag demo">تجريبي</span>}
      </div>
      <h3>{shortName(p.name)}</h3>
      {price && (
        <div>
          <div className="price"><b className="num">{price.value.replace(" ر.س", "")}</b><span>ر.س {price.unit}</span></div>
          {price.extra && <span className="small" style={{ opacity: 0.75 }}>{price.extra}</span>}
        </div>
      )}
      <p className="for">{p.audience}</p>
      <span className="more">التفاصيل والاشتراك <IconArrow size={18} /></span>
    </Link>
  );
}
