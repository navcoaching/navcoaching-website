import CalculatorForm from "./CalculatorForm";
import IntakeCalculator from "./IntakeCalculator";
import { isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { CALC, type CalcText } from "./text";

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/calculator", { title: CALC[lang].metaTitle, description: CALC[lang].metaDesc });
}

export default async function Calculator({ params }: P) {
  const lang = await langOf(params);
  const u: CalcText = CALC[lang];
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{u.title}</h1>
          <p className="lead">{u.lead}</p>
          <nav className="row" style={{ marginTop: 18 }} aria-label={u.navAria}>
            <a className="btn btn-ghost btn-sm" href="#daily">{u.dailyTitle}</a>
            <a className="btn btn-ghost btn-sm" href="#energy-balance">{u.ebTitle}</a>
          </nav>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap stack" style={{ ["--space" as string]: "22px", maxWidth: 900 }}>
          <div id="daily" className="stack" style={{ ["--space" as string]: "12px", scrollMarginTop: 90 }}>
            <h2 style={{ fontSize: 26 }}>{u.dailyTitle}</h2>
            <p className="muted">{u.dailyLead}</p>
            <IntakeCalculator lang={lang} />
          </div>
          <div id="energy-balance" className="stack" style={{ ["--space" as string]: "12px", scrollMarginTop: 90, marginTop: 24 }}>
            <h2 style={{ fontSize: 26 }}>{u.ebTitle}</h2>
            <p className="muted">{u.ebLead}</p>
            <CalculatorForm lang={lang} />
          </div>
          <p className="alert warn" role="note">{u.disclaimer}</p>
          <div className="stack" style={{ ["--space" as string]: "12px" }}>
            <h2 style={{ fontSize: 24 }}>{u.faqTitle}</h2>
            <div className="faq">
              {u.faq.map((f) => (
                <details key={f.q}>
                  <summary>{f.q}</summary>
                  <div className="ans"><p>{f.a}</p></div>
                </details>
              ))}
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
