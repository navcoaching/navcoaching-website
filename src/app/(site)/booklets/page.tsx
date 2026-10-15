import type { Metadata } from "next";
import Link from "next/link";
import { getBookletsForSale } from "@/lib/data";
import { getCurrentUser } from "@/lib/session";
import { IconBook } from "@/components/Icons";
import BookletBuyButton from "./BookletBuyButton";

export const metadata: Metadata = {
  title: "كتيبات التمرين والتغذية PDF",
  description: "كتيبات PDF من الكوتش ساره في التمرين والتغذية. الشراء من الحساب بتحويل بنكي، والتحميل من «حسابي» بعد تأكيد الدفع. ومشمولة لمشتركي باقات المتابعة.",
  alternates: { canonical: "/booklets" },
};

const sar = (h: number) => (h / 100).toLocaleString("en-US", { maximumFractionDigits: 2 });

/** رقم الجوال المحفوظ مقسوم لرمز الدولة والرقم المحلي (لتعبئة نموذج الشراء) */
function splitPhone(p: string | null) {
  if (!p) return { cc: "+966", national: "" };
  for (const cc of ["+966", "+971", "+965", "+973", "+974", "+968"]) if (p.startsWith(cc)) return { cc, national: p.slice(cc.length) };
  return { cc: "أخرى", national: p.replace(/^\+/, "") };
}

export default async function Booklets() {
  const user = await getCurrentUser().catch(() => null);
  const items = await getBookletsForSale(user?.id ?? null);
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">الكتيبات</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>كتيبات الكوتش ساره</h1>
          <p className="lead" style={{ maxWidth: 720 }}>كتيبات PDF في التمرين والتغذية. الشراء من الحساب بتحويل بنكي، والتحميل من «حسابي» بعد تأكيد الدفع.</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap stack" style={{ ["--space" as string]: "22px" }}>
          <p className="alert info" style={{ margin: 0 }}>مشتركو باقات المتابعة (الأساسية، المكثفة، المتقدمة): كل الكتيبات مشمولة في الاشتراك وتظهر في «حسابي».</p>
          {items.length === 0 ? (
            <div className="card stack">
              <p style={{ margin: 0 }}>ما فيه كتيبات معروضة للبيع حالياً.</p>
              <Link href="/programs" className="btn" style={{ width: "fit-content" }}>البرامج والأسعار</Link>
            </div>
          ) : (
            <ul className="fp-grid" data-testid="booklets-sale">
              {items.map((b) => (
                <li key={b.id} className="card fp-card" data-testid="booklet-card">
                  <div className="fp-cover"><span aria-hidden="true"><IconBook size={44} /></span></div>
                  <div className="fp-body">
                    <span className="tag soft">PDF · <bdi className="num">{(b.file_size / 1024 / 1024).toFixed(1)}</bdi> م.ب</span>
                    <h2>{b.title}</h2>
                    {b.description && <p className="muted" style={{ margin: 0 }}>{b.description}</p>}
                    <p style={{ margin: 0 }}><b className="num" style={{ fontSize: 22 }}>{sar(b.price_halalas)}</b> ر.س</p>
                  </div>
                  <BookletBuyButton id={b.id} price={sar(b.price_halalas)} loggedIn={Boolean(user)} owned={b.owned}
                    pendingOrder={b.pending_order} phone={splitPhone(user?.phone ?? null)} />
                </li>
              ))}
            </ul>
          )}
          <p className="small muted">الكتيبات ملفات رقمية للاستخدام الشخصي. للبرنامج المصمم حسب الهدف مع متابعة: <Link href="/programs">البرامج</Link>.</p>
        </div>
      </section>
    </div>
  );
}
