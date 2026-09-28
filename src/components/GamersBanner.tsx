import Link from "next/link";
import { riyals, waLink } from "@/lib/format";
import type { Product } from "@/lib/data";

const POINTS = [
  ["⚡", "تركيز وأداء ذهني أعلى", "طاقة ثابتة وتركيز أطول في الجلسات الطويلة."],
  ["🎯", "سرعة استجابة أفضل", "تمارين وعادات تدعم رد الفعل واليقظة أثناء اللعب."],
  ["🪑", "ظهر ورقبة أريح", "تمارين تساعد تخفف آلام الظهر والرقبة من الجلوس الطويل."],
] as const;

/** بانر «باقة القيمرز» في الصفحة الرئيسية. يظهر فقط إذا نُشرت باقة بالرابط /programs/gamers */
export default function GamersBanner({ product, whatsapp }: { product: Product | undefined; whatsapp: string }) {
  if (!product || product.status !== "published") return null;
  const prices = product.offers.filter((o) => o.active).map((o) => o.price_halalas);
  const from = prices.length ? Math.min(...prices) : null;
  return (
    <section className="section gamers" id="gamers" aria-labelledby="gamers-h" data-testid="gamers-banner">
      <div className="wrap">
        <div className="gamers-banner reveal">
          <div className="gamers-copy">
            <span className="gamers-tag">🎮 للقيمرز</span>
            <h2 id="gamers-h">قيمر؟ عندي باقة مصممة لك</h2>
            <p className="gamers-lead">لأني جاية من عالم الرياضات الإلكترونية، صممت باقة خاصة للقيمرز: لياقة أفضل داخل وخارج الشاشة.</p>
            <div className="row gamers-cta">
              <Link href="/programs/gamers" className="btn btn-cyan">شوف باقة القيمرز ←</Link>
              <a href={waLink(whatsapp, "مرحباً، أبي أعرف أكثر عن باقة القيمرز")} className="btn btn-ghost gamers-ghost" target="_blank" rel="noopener">اسألني على واتساب</a>
            </div>
            {from != null && <p className="gamers-price">تبدأ من <b className="num">{riyals(from)}</b></p>}
          </div>
          <ul className="gamers-points">
            {POINTS.map(([icon, title, body]) => (
              <li key={title}>
                <span className="gamers-ico" aria-hidden="true">{icon}</span>
                <div><b>{title}</b><p>{body}</p></div>
              </li>
            ))}
            <li className="gamers-note">الألم المستمر أو الحاد يحتاج تقييم مختص قبل البدء.</li>
          </ul>
        </div>
      </div>
    </section>
  );
}
