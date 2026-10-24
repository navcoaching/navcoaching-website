import Link from "next/link";
import type { Product } from "@/lib/data";
import { categoryLabel, CURRENCY, offerLabel, priceNum, riyals, shortName } from "@/lib/format";
import { href, type Lang } from "@/lib/lang";
import { t } from "@/i18n/ui";
import { IconArrow } from "./Icons";

export function fromPrice(p: Product, lang: Lang = "ar") {
  const active = p.offers.filter((o) => o.active);
  if (!active.length) return null;
  const u = t(lang).product;
  // مثل الموقع الحالي: سعر الشهر الواحد إن وُجد، وإلا أقل سعر
  const monthly = active.find((o) => o.months === 1);
  if (monthly) {
    const longer = active.filter((o) => o.months > 1).sort((a, b) => a.months - b.months)[0];
    return { value: riyals(monthly.price_halalas, lang), unit: u.perMonthUnit, extra: longer ? u.orFor(riyals(longer.price_halalas, lang), offerLabel(longer, lang)) : null };
  }
  const min = active.reduce((a, b) => (b.price_halalas < a.price_halalas ? b : a));
  return { value: riyals(min.price_halalas, lang), unit: min.months === 0 ? u.oneTime : offerLabel(min, lang), extra: null };
}

export default function ProductCard({ p, index = 0, lang = "ar" }: { p: Product; index?: number; lang?: Lang }) {
  const price = fromPrice(p, lang);
  const u = t(lang).home;
  return (
    <Link href={href(lang, `/programs/${p.slug}`)} className={`pcard reveal ${p.recommended ? "rec" : ""}`} style={{ ["--d" as string]: `${index * 70}ms` }}>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <span className="kicker">{categoryLabel(p.category, lang)}</span>
        {p.recommended && <span className="tag">{u.mostPopular}</span>}
        {p.is_demo && <span className="tag demo">{u.demo}</span>}
      </div>
      <h3>{shortName(p.name)}</h3>
      {price && (
        <div>
          <div className="price"><b className="num">{priceNum(price.value)}</b><span>{CURRENCY[lang]} {price.unit}</span></div>
          {price.extra && <span className="small" style={{ opacity: 0.75 }}>{price.extra}</span>}
        </div>
      )}
      <p className="for">{p.audience}</p>
      <span className="more">{u.detailsSubscribe} <IconArrow size={18} /></span>
    </Link>
  );
}
