"use client";
import { useRef, useState } from "react";
import { tiktokId, youtubeId } from "@/lib/youtube";

/**
 * زر «▶ فيديو» يشغّل مقطع يوتيوب داخل نافذة منبثقة في الموقع (بدل الخروج لتطبيق يوتيوب).
 * يدعم يوتيوب وتيك توك (الرابط الكامل). المشغّل يُحمَّل فقط عند الفتح ويُزال عند الإغلاق (يوقف الصوت). أي رابط آخر يفتح كرابط عادي.
 */
export default function VideoButton({ url, label = "▶ فيديو", title, className = "btn btn-ghost btn-sm", testId }: {
  url: string; label?: React.ReactNode; title?: string; className?: string; testId?: string;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const [open, setOpen] = useState(false);
  const yt = youtubeId(url), tt = yt ? null : tiktokId(url);
  const id = yt ?? tt;
  if (!id) return <a className={className} href={url} target="_blank" rel="noopener noreferrer" data-testid={testId}>{label}</a>;
  const vertical = Boolean(tt) || /\/shorts\//.test(url);
  const show = (e: React.MouseEvent) => {
    e.preventDefault(); e.stopPropagation(); // داخل <summary> ما يطوي البطاقة
    setOpen(true);
    ref.current?.showModal();
  };
  const close = () => { ref.current?.close(); };
  return (
    <>
      <button type="button" className={className} onClick={show} data-testid={testId} aria-haspopup="dialog">{label}</button>
      <dialog ref={ref} className={`video-modal${vertical ? " vertical" : ""}`} onClose={() => setOpen(false)} aria-label={title ?? "فيديو"}
        onClick={(e) => { if (e.target === e.currentTarget) close(); }}>
        <div className="video-modal-box">
          <div className="video-modal-head">
            {title && <b className="small"><bdi dir="ltr">{title}</bdi></b>}
            <button type="button" className="btn btn-ghost btn-sm" onClick={close} aria-label="إغلاق الفيديو">✕</button>
          </div>
          <div className="video-modal-frame">
            {open && (
              <iframe src={tt ? `https://www.tiktok.com/embed/v2/${tt}` : `https://www.youtube-nocookie.com/embed/${id}?autoplay=1&rel=0&playsinline=1&modestbranding=1`}
                title={title ?? "فيديو"} allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowFullScreen data-testid="video-iframe" />
            )}
          </div>
          <a className="small muted" href={url} target="_blank" rel="noopener noreferrer">{tt ? "ما اشتغل؟ افتحه في تيك توك" : "ما اشتغل؟ افتحه في يوتيوب"}</a>
        </div>
      </dialog>
    </>
  );
}
