import Link from "next/link";
import Shots from "@/components/Shots";
import { getSettings } from "@/lib/data";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600;

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/program-preview", { title: t(lang).preview.metaTitle, description: t(lang).preview.metaDesc });
}

/** معاينة لوحة المتدرب (انتقلت من الرئيسية) */
export default async function ProgramPreview({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).preview;
  const s = await getSettings(lang);
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{u.title}</h1>
          <p className="lead">{u.lead}{u.arNote ? ` ${u.arNote}` : ""}</p>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap">
          <Shots shots={s.program_shots} />
          <p style={{ marginTop: 24 }}><Link href={href(lang, "/programs")} className="btn">{u.pricing}</Link></p>
        </div>
      </section>
    </div>
  );
}
