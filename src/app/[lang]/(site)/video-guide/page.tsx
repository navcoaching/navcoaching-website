import Link from "next/link";
import YouTubeShort from "@/components/YouTubeShort";
import { getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";
import { href, isLang, type Lang } from "@/lib/lang";
import { pageMeta } from "@/lib/meta";
import { t } from "@/i18n/ui";

export const revalidate = 3600;

type P = { params: Promise<{ lang: string }> };
const langOf = async (params: P["params"]): Promise<Lang> => { const { lang } = await params; return isLang(lang) ? lang : "ar"; };
export async function generateMetadata({ params }: P) {
  const lang = await langOf(params);
  return pageMeta(lang, "/video-guide", { title: t(lang).guide.metaTitle, description: t(lang).guide.metaDesc });
}

/** فيديو شرح الموقع (انتقل من الرئيسية). الرابط من لوحة الإدارة ← المحتوى والإعدادات */
export default async function VideoGuide({ params }: P) {
  const lang = await langOf(params);
  const u = t(lang).guide;
  const s = await getSettings(lang);
  const id = youtubeId(s.guide_video?.url);
  const vertical = /\/shorts\//.test(s.guide_video?.url ?? "");
  const title = (lang === "ar" && s.guide_video?.title) || u.title;
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">{u.eyebrow}</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{title}</h1>
          {lang === "ar" && s.guide_video?.body && <p className="lead">{s.guide_video.body}</p>}
        </div>
      </section>
      <section className="section tight" data-testid="guide-video">
        <div className={vertical ? "wrap short" : "wrap guide-video"}>
          {id ? <YouTubeShort id={id} title={title} wide={!vertical} />
            : <p className="muted">{u.soon}</p>}
          <p className="muted small" style={{ marginTop: 16 }}>{id && u.note}<Link href={href(lang, "/program-preview")}>{u.preview}</Link></p>
        </div>
      </section>
    </div>
  );
}
