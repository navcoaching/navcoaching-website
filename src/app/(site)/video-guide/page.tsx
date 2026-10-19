import type { Metadata } from "next";
import Link from "next/link";
import YouTubeShort from "@/components/YouTubeShort";
import { getSettings } from "@/lib/data";
import { youtubeId } from "@/lib/youtube";

export const metadata: Metadata = {
  title: "فيديو شرح استخدام الموقع",
  description: "شرح استخدام موقع Nav Coaching خطوة بخطوة: الاشتراك، الاستبيان، ومتابعة البرنامج من الحساب.",
};
export const revalidate = 3600;

/** فيديو شرح الموقع (انتقل من الرئيسية). الرابط من لوحة الإدارة ← المحتوى والإعدادات */
export default async function VideoGuide() {
  const s = await getSettings();
  const id = youtubeId(s.guide_video?.url);
  const vertical = /\/shorts\//.test(s.guide_video?.url ?? "");
  const title = s.guide_video?.title || "شرح استخدام الموقع خطوة بخطوة";
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">أداة مجانية</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>{title}</h1>
          {s.guide_video?.body && <p className="lead">{s.guide_video.body}</p>}
        </div>
      </section>
      <section className="section tight" data-testid="guide-video">
        <div className={vertical ? "wrap short" : "wrap guide-video"}>
          {id ? <YouTubeShort id={id} title={title} wide={!vertical} />
            : <p className="muted">الفيديو قريباً.</p>}
          <p className="muted small" style={{ marginTop: 16 }}>{id && "الفيديو لا يعمل تلقائياً: تشغيل المقطع من الصورة، أو فتحه في تطبيق يوتيوب. "}<Link href="/program-preview">نظرة داخل البرنامج ←</Link></p>
        </div>
      </section>
    </div>
  );
}
