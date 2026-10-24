import Link from "next/link";
import RichText from "@/components/RichText";
import { CopyButton } from "@/components/FormBits";
import { getFaqs, getSettings } from "@/lib/data";
import { waLink } from "@/lib/format";
import JsonLd, { plain, siteUrl } from "@/components/JsonLd";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600; // ساعة. تعديلات الإدارة تُحدّث الصفحات فوراً (revalidatePath)، فلا حاجة لإعادة توليد كل 5 دقائق (وهي ما تسبب بطء أول زائر)

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/faq", { title: t(lang).faq.metaTitle, description: t(lang).faq.metaDesc });
}

export default async function Faq({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).faq;
  const [faqs, s] = await Promise.all([getFaqs(lang), getSettings(lang)]);
  return (
    <div className="pub">
      <JsonLd data={{ "@context": "https://schema.org", "@type": "FAQPage", url: `${siteUrl()}${href(lang, "/faq")}`, inLanguage: lang, mainEntity: faqs.map((f) => ({ "@type": "Question", name: plain(f.question), acceptedAnswer: { "@type": "Answer", text: plain(f.answer) } })) }} />
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{u.title}</h1>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap account-layout">
          <div className="faq">
            {faqs.map((f) => (
              <details key={f.id}>
                <summary>{f.question}</summary>
                <div className="ans"><RichText text={f.answer} /></div>
              </details>
            ))}
          </div>
          <aside className="stack">
            <div className="card">
              <h2 style={{ fontSize: 18, marginBottom: 10 }}>{u.bank}</h2>
              <div className="bank">
                <div><span className="muted small">{u.accountName}</span><div>{s.bank.accountName}</div></div>
                <div><span className="muted small">{u.bankName}</span><div>{s.bank.bankName}</div></div>
                <div><span className="muted small">{u.iban}</span><div className="iban" dir="ltr">{s.bank.iban.replace(/\s+/g, "").replace(/(.{4})/g, "$1 ").trim()}</div></div>
                <CopyButton value={s.bank.iban} label={u.copyIban} done={t(lang).common.copied} />
              </div>
              <p className="small muted" style={{ marginTop: 10 }}>{u.bankNote}</p>
            </div>
            <div className="card flat">
              <p>{u.noAnswer}</p>
              <a className="btn btn-block" style={{ marginTop: 10 }} href={waLink(s.contact.whatsapp)} target="_blank" rel="noopener">{u.whatsapp}</a>
              <Link className="text-link" style={{ marginTop: 8 }} href={href(lang, "/policies")}>{u.policies}</Link>
            </div>
          </aside>
        </div>
      </section>
    </div>
  );
}
