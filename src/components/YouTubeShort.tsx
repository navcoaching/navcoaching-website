"use client";
import { useState } from "react";
import { IconPlay } from "./Icons";

/**
 * لا يُحمّل مشغّل يوتيوب إلا بعد نقر المستخدم (أخف وأكثر خصوصية، ولا تشغيل تلقائي بصوت).
 * يستخدم youtube-nocookie. يوجد رابط بديل لفتح المقطع في تطبيق يوتيوب على الجوال.
 */
export default function YouTubeShort({ id, title, wide = false }: { id: string; title: string; wide?: boolean }) {
  const [play, setPlay] = useState(false);
  const [thumbOk, setThumbOk] = useState(true);
  return (
    <div className="stack" style={{ ["--space" as string]: "12px" }}>
      <div className={`short-frame${wide ? " wide" : ""}`}>
        {play ? (
          <iframe
            src={`https://www.youtube-nocookie.com/embed/${id}?autoplay=1&playsinline=1&rel=0&modestbranding=1`}
            title={title}
            allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
            allowFullScreen
          />
        ) : (
          <>
            {thumbOk && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={wide ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : `https://i.ytimg.com/vi/${id}/oar2.jpg`} alt="" loading="lazy" decoding="async"
                onError={(e) => {
                  const img = e.currentTarget;
                  if (!wide && !img.dataset.fallback) { img.dataset.fallback = "1"; img.src = `https://i.ytimg.com/vi/${id}/hqdefault.jpg`; }
                  else setThumbOk(false);
                }} />
            )}
            <button type="button" className="short-play" onClick={() => setPlay(true)} aria-label={`تشغيل المقطع: ${title}`}>
              <span className="disc"><IconPlay size={30} /></span>
              <span className="cap">اضغط للتشغيل</span>
            </button>
          </>
        )}
      </div>
      <a className="small center" href={wide ? `https://www.youtube.com/watch?v=${id}` : `https://www.youtube.com/shorts/${id}`} target="_blank" rel="noopener">فتح المقطع في يوتيوب ↗</a>
    </div>
  );
}
